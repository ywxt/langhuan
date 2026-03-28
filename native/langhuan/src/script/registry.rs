//! Script registry — maps feed IDs to their Lua script files on disk.
//!
//! The registry is driven by a `registry.toml` file in the scripts directory:
//!
//! ```toml
//! [[feeds]]
//! id      = "example-feed"
//! name    = "範例書源"
//! version = "1.0.0"
//! file    = "example-feed/1.0.0.lua"
//!
//! [[feeds]]
//! id      = "another-feed"
//! name    = "另一書源"
//! version = "2.1.0"
//! file    = "another-feed/2.1.0.lua"
//! ```
//!
//! **Upgrade strategy**: write the new script to a new versioned file, then
//! update `version` and `file` in `registry.toml`.  Old files are kept for
//! potential rollback.
//!
//! This module has **no dependency on rinf** — it is pure Rust / tokio.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::error::{Error, Result};
use crate::script::engine::ScriptEngine;
use crate::script::lua_feed::LuaFeed;

// ---------------------------------------------------------------------------
// TOML data structures
// ---------------------------------------------------------------------------

/// A single entry in `registry.toml`.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct RegistryEntry {
    /// Unique identifier for this feed (must match the `@id` in the script header).
    pub id: String,
    /// Human-readable display name (stored here to avoid reading every script
    /// file just to list feeds).
    pub name: String,
    /// Currently active version string (e.g. `"1.0.0"`).
    pub version: String,
    /// Optional author name.
    pub author: Option<String>,
    /// Path to the script file, **relative to the registry base directory**.
    pub file: String,
}

/// Root structure of `registry.toml`.
#[derive(Debug, Default, Deserialize, Serialize)]
struct RegistryFile {
    #[serde(default)]
    feeds: Vec<RegistryEntry>,
}

// ---------------------------------------------------------------------------
// ScriptRegistry
// ---------------------------------------------------------------------------

/// An in-memory index of all registered feed scripts.
///
/// Load once with [`ScriptRegistry::load`], then share via [`std::sync::Arc`].
/// The registry is **read-only** after construction — no locking required.
pub struct ScriptRegistry {
    base_dir: PathBuf,
    feeds: HashMap<String, RegistryItem>,
}

/// Runtime availability state for a registry entry.
pub enum FeedSlot {
    Ready(Arc<LuaFeed>),
    Failed,
}

/// Registry entry together with its runtime availability.
pub struct RegistryItem {
    pub entry: RegistryEntry,
    pub slot: FeedSlot,
}

impl std::fmt::Debug for ScriptRegistry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let mut ids: Vec<&str> = self.feeds.keys().map(String::as_str).collect();
        ids.sort_unstable();

        f.debug_struct("ScriptRegistry")
            .field("base_dir", &self.base_dir)
            .field("feeds", &ids)
            .finish()
    }
}

impl ScriptRegistry {
    /// Load the registry from `<base_dir>/registry.toml`.
    ///
    /// # Errors
    /// - [`Error::RegistryNotFound`] — the file cannot be read.
    /// - [`Error::RegistryParse`] — the TOML is malformed.
    /// - [`Error::DuplicateFeedId`] — two entries share the same `id`.
    pub async fn load_entries(base_dir: &Path) -> Result<HashMap<String, RegistryEntry>> {
        let registry_path = registry_path(base_dir);

        let content = tokio::fs::read_to_string(&registry_path)
            .await
            .map_err(Error::RegistryNotFound)?;

        let registry_file: RegistryFile =
            toml::from_str(&content).map_err(|e| Error::RegistryParse {
                message: e.to_string(),
            })?;

        let mut entries: HashMap<String, RegistryEntry> =
            HashMap::with_capacity(registry_file.feeds.len());
        for entry in registry_file.feeds {
            if entries.contains_key(&entry.id) {
                return Err(Error::DuplicateFeedId { id: entry.id });
            }
            entries.insert(entry.id.clone(), entry);
        }

        Ok(entries)
    }

    pub async fn load_feed(
        base_dir: &Path,
        entry: &RegistryEntry,
        engine: &ScriptEngine,
    ) -> Result<LuaFeed> {
        let script_path = base_dir.join(&entry.file);
        let script = tokio::fs::read_to_string(&script_path)
            .await
            .map_err(Error::RegistryNotFound)?;

        let feed = engine.load_feed(&script).await?;
        Ok(feed)
    }

    pub fn new(
        base_dir: &Path,
        entries: HashMap<String, RegistryEntry>,
        feeds: HashMap<String, Arc<LuaFeed>>,
    ) -> Result<Self> {
        if !feeds.keys().all(|id| entries.contains_key(id)) {
            return Err(Error::RegistryParse {
                message: "compiled feeds keys must be a subset of entries keys".to_string(),
            });
        }

        let items = entries
            .into_iter()
            .map(|(id, entry)| {
                let slot = match feeds.get(&id) {
                    Some(feed) => FeedSlot::Ready(Arc::clone(feed)),
                    None => FeedSlot::Failed,
                };
                (id, RegistryItem { entry, slot })
            })
            .collect();

        Ok(Self {
            base_dir: base_dir.to_owned(),
            feeds: items,
        })
    }

    /// Install or upgrade a feed script into the registry directory.
    ///
    /// Steps:
    /// 1. Parse metadata from `content` via [`super::meta::parse_meta`].
    /// 2. Write the Lua file to `<base_dir>/<feed_id>/<version>.lua`.
    /// 3. Update `<base_dir>/registry.toml`, replacing any existing entry with
    ///    the same `id` (upgrade) or appending a new entry.
    /// 4. Return the new [`RegistryEntry`].
    ///
    /// # Errors
    /// - [`Error::ScriptParse`] / [`Error::InvalidFeed`] — script header invalid.
    /// - [`Error::RegistryWrite`] — a filesystem write failed.
    /// - [`Error::RegistryParse`] — existing `registry.toml` is malformed.
    pub async fn install_feed(
        &mut self,
        content: &str,
        engine: &ScriptEngine,
    ) -> Result<RegistryEntry> {
        // 1. Parse metadata.
        let (feed_meta, _) = super::meta::parse_meta(content)?;

        let feed_id = &feed_meta.id;
        let version = &feed_meta.version;

        // 2. Write the Lua script file.
        let script_dir = self.base_dir.join(feed_id.as_str());
        tokio::fs::create_dir_all(&script_dir)
            .await
            .map_err(|e| Error::RegistryWrite(e.to_string()))?;

        let rel_path = feed_path(feed_id, version);
        let script_path = self.base_dir.join(&rel_path);
        tokio::fs::write(&script_path, content)
            .await
            .map_err(|e| Error::RegistryWrite(e.to_string()))?;

        // 3. Upsert in memory and persist atomically.
        let new_entry = RegistryEntry {
            id: feed_id.clone(),
            name: feed_meta.name.clone(),
            version: version.clone(),
            author: feed_meta.author.clone(),
            file: rel_path.display().to_string(),
        };

        // 3. Compile from disk through registry path to keep install flow
        // consistent with runtime loading behavior.
        let compiled_feed = match Self::load_feed(&self.base_dir, &new_entry, engine).await {
            Ok(feed) => Arc::new(feed),
            Err(e) => {
                let _ = tokio::fs::remove_file(&script_path).await;
                return Err(e);
            }
        };

        let previous = self.feeds.insert(
            feed_id.clone(),
            RegistryItem {
                entry: new_entry.clone(),
                slot: FeedSlot::Ready(compiled_feed),
            },
        );
        if let Err(e) = self.persist_registry().await {
            match previous {
                Some(old) => {
                    self.feeds.insert(feed_id.clone(), old);
                }
                None => {
                    self.feeds.remove(feed_id);
                }
            }
            // Best-effort cleanup for newly written script file when install
            // failed before becoming durable in registry.toml.
            let _ = tokio::fs::remove_file(&script_path).await;
            return Err(e);
        }

        Ok(new_entry)
    }

    /// Remove a feed from the registry, rolling back both the TOML entry and the
    /// script file on disk.
    ///
    /// # Errors
    /// - [`Error::RegistryNotFound`] — `registry.toml` does not exist.
    /// - [`Error::RegistryParse`] — `registry.toml` is malformed.
    /// - [`Error::FeedNotFound`] — no entry with `feed_id` exists.
    /// - [`Error::RegistryWrite`] — a filesystem write failed.
    pub async fn remove_feed(&mut self, feed_id: &str) -> Result<()> {
        let removed = self
            .feeds
            .remove(feed_id)
            .ok_or_else(|| Error::FeedNotFound {
                id: feed_id.to_owned(),
            })?;
        let entry = removed.entry.clone();

        if let Err(e) = self.persist_registry().await {
            self.feeds.insert(feed_id.to_owned(), removed);
            return Err(e);
        }

        // Best-effort: delete the script file; ignore NotFound.
        let script_path = self.base_dir.join(&entry.file);
        if let Err(e) = tokio::fs::remove_file(&script_path).await
            && e.kind() != std::io::ErrorKind::NotFound
        {
            self.feeds.insert(feed_id.to_owned(), removed);
            if let Err(rollback_err) = self.persist_registry().await {
                return Err(Error::RegistryWrite(format!(
                    "remove file failed: {}; rollback failed: {}",
                    e, rollback_err
                )));
            }
            return Err(Error::RegistryWrite(e.to_string()));
        }

        Ok(())
    }

    /// Ensure `<base_dir>/registry.toml` exists, creating it empty if necessary.
    ///
    /// # Errors
    /// - [`Error::RegistryWrite`] — the file could not be created.
    pub async fn ensure_registry(base_dir: &Path) -> Result<()> {
        let registry_path = registry_path(base_dir);
        if !registry_path.exists() {
            let empty = toml::to_string_pretty(&RegistryFile::default())
                .map_err(|e| Error::RegistryWrite(e.to_string()))?;
            write_atomic(&registry_path, &empty).await?;
        }
        Ok(())
    }

    /// Iterate over all registered feed entries, including unavailable ones.
    pub fn list_entries(&self) -> impl Iterator<Item = &RegistryEntry> {
        self.feeds.values().map(|item| &item.entry)
    }

    /// Iterate over all compiled feeds.
    pub fn list_feeds(&self) -> impl Iterator<Item = (&RegistryEntry, &Arc<LuaFeed>)> {
        self.feeds.values().filter_map(|item| match &item.slot {
            FeedSlot::Ready(feed) => Some((&item.entry, feed)),
            FeedSlot::Failed => None,
        })
    }

    /// Return the number of registered feeds.
    pub fn len(&self) -> usize {
        self.feeds.len()
    }

    /// Return the number of feeds currently available for requests.
    pub fn ready_len(&self) -> usize {
        self.feeds
            .values()
            .filter(|item| matches!(item.slot, FeedSlot::Ready(_)))
            .count()
    }

    /// Return `true` if no feeds are registered.
    pub fn is_empty(&self) -> bool {
        self.feeds.is_empty()
    }

    /// Return `true` if a feed with `feed_id` is currently registered.
    pub fn has_feed(&self, feed_id: &str) -> bool {
        self.feeds
            .get(feed_id)
            .is_some_and(|item| matches!(item.slot, FeedSlot::Ready(_)))
    }

    /// Return `true` if an entry with `feed_id` exists in the registry.
    pub fn has_entry(&self, feed_id: &str) -> bool {
        self.feeds.contains_key(feed_id)
    }

    /// Return the entry metadata for `feed_id`.
    pub fn entry(&self, feed_id: &str) -> Option<&RegistryEntry> {
        self.feeds.get(feed_id).map(|item| &item.entry)
    }

    /// Return the feed for `feed_id`.
    pub fn feed(&self, feed_id: &str) -> Option<(&RegistryEntry, &Arc<LuaFeed>)> {
        self.feeds.get(feed_id).and_then(|item| match &item.slot {
            FeedSlot::Ready(feed) => Some((&item.entry, feed)),
            FeedSlot::Failed => None,
        })
    }

    async fn persist_registry(&self) -> Result<()> {
        let mut entries: Vec<RegistryEntry> = self
            .feeds
            .values()
            .map(|item| item.entry.clone())
            .collect();
        entries.sort_by(|a, b| a.id.cmp(&b.id));

        let registry_file = RegistryFile { feeds: entries };
        let toml_content = toml::to_string_pretty(&registry_file)
            .map_err(|e| Error::RegistryWrite(e.to_string()))?;
        let registry_path = registry_path(&self.base_dir);
        write_atomic(&registry_path, &toml_content).await
    }
}

// ---------------------------------------------------------------------------
// install_feed — write a new or upgraded script to disk
// ---------------------------------------------------------------------------

/// Return the canonical path to `registry.toml` inside `base_dir`.
#[inline]
fn registry_path(base_dir: &Path) -> PathBuf {
    base_dir.join("registry.toml")
}

#[inline]
fn feed_path(feed_id: &str, version: &str) -> PathBuf {
    Path::new(feed_id).join(format!("{}.lua", version))
}

async fn write_atomic(path: &Path, content: &str) -> Result<()> {
    let mut tmp_path = path.to_path_buf();
    let ext = path
        .extension()
        .and_then(|s| s.to_str())
        .map(|ext| format!("{ext}.tmp"))
        .unwrap_or_else(|| "tmp".to_owned());
    tmp_path.set_extension(ext);

    tokio::fs::write(&tmp_path, content)
        .await
        .map_err(|e| Error::RegistryWrite(e.to_string()))?;

    if let Err(rename_err) = tokio::fs::rename(&tmp_path, path).await {
        #[cfg(windows)]
        {
            if path.exists() {
                tokio::fs::remove_file(path)
                    .await
                    .map_err(|e| Error::RegistryWrite(e.to_string()))?;
                tokio::fs::rename(&tmp_path, path)
                    .await
                    .map_err(|e| Error::RegistryWrite(e.to_string()))?;
                return Ok(());
            }
        }

        let _ = tokio::fs::remove_file(&tmp_path).await;
        return Err(Error::RegistryWrite(rename_err.to_string()));
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;
    use tokio::fs;

    use crate::script::engine::ScriptEngine;

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    /// Write `registry.toml` and optional script files into a temp directory.
    async fn setup_dir(registry_toml: &str, scripts: &[(&str, &str)]) -> TempDir {
        let dir = tempfile::tempdir().expect("tempdir");
        fs::write(dir.path().join("registry.toml"), registry_toml)
            .await
            .expect("write registry.toml");
        for (rel_path, content) in scripts {
            let full = dir.path().join(rel_path);
            if let Some(parent) = full.parent() {
                fs::create_dir_all(parent).await.expect("create_dir_all");
            }
            fs::write(&full, content).await.expect("write script");
        }
        dir
    }

    const MINIMAL_SCRIPT: &str = r#"-- ==Feed==
-- @id      test-feed
-- @name    Test Feed
-- @version 1.0.0
-- @base_url https://example.com
-- ==/Feed==
return {}
"#;

        fn make_valid_script(feed_id: &str, version: &str) -> String {
                format!(
                        r#"-- ==Feed==
-- @id      {feed_id}
-- @name    Test Feed
-- @version {version}
-- @base_url https://example.com
-- ==/Feed==
return {{
    search = {{
        request = function(...) return {{ url = "https://example.com" }} end,
        parse = function(...) return {{ items = {{}}, next_cursor = nil }} end,
    }},
    book_info = {{
        request = function(...) return {{ url = "https://example.com" }} end,
        parse = function(...) return nil end,
    }},
    chapters = {{
        request = function(...) return {{ url = "https://example.com" }} end,
        parse = function(...) return {{ items = {{}}, next_cursor = nil }} end,
    }},
    paragraphs = {{
        request = function(...) return {{ url = "https://example.com" }} end,
        parse = function(...) return {{ items = {{}}, next_cursor = nil }} end,
    }},
}}
"#
                )
        }

        async fn compile_feed(script: &str) -> Arc<LuaFeed> {
                let engine = ScriptEngine::new();
                Arc::new(engine.load_feed(script).await.expect("compile feed"))
        }

        async fn create_registry_with_single_feed(
                base_dir: &Path,
                feed_id: &str,
                version: &str,
        ) -> ScriptRegistry {
                let script = make_valid_script(feed_id, version);
                let compiled_feed = compile_feed(&script).await;

                let entry = RegistryEntry {
                        id: feed_id.to_owned(),
                        name: "Test Feed".to_owned(),
                        version: version.to_owned(),
                        author: None,
                        file: format!("{feed_id}/{version}.lua"),
                };

                let script_path = base_dir.join(&entry.file);
                if let Some(parent) = script_path.parent() {
                        fs::create_dir_all(parent)
                                .await
                                .expect("create feed script dir");
                }
                fs::write(&script_path, script)
                        .await
                        .expect("write feed script");

                let mut entries = HashMap::new();
                entries.insert(feed_id.to_owned(), entry);

                let mut feeds = HashMap::new();
                feeds.insert(feed_id.to_owned(), compiled_feed);

                ScriptRegistry::new(base_dir, entries, feeds).expect("create registry")
        }

    // -----------------------------------------------------------------------
    // load: happy path
    // -----------------------------------------------------------------------

    #[tokio::test]
    async fn load_single_entry() {
        let toml = r#"
[[feeds]]
id      = "test-feed"
name    = "Test Feed"
version = "1.0.0"
file    = "test-feed/1.0.0.lua"
"#;
        let dir = setup_dir(toml, &[("test-feed/1.0.0.lua", MINIMAL_SCRIPT)]).await;
        let registry = ScriptRegistry::load_entries(dir.path())
            .await
            .expect("load");

        assert_eq!(registry.len(), 1);
        let entry = registry.get("test-feed").expect("entry");
        assert_eq!(entry.version, "1.0.0");
        assert_eq!(entry.name, "Test Feed");
        assert!(entry.author.is_none());
    }

    #[tokio::test]
    async fn load_multiple_entries() {
        let toml = r#"
[[feeds]]
id      = "feed-a"
name    = "Feed A"
version = "1.0.0"
file    = "feed-a/1.0.0.lua"

[[feeds]]
id      = "feed-b"
name    = "Feed B"
version = "2.0.0"
author  = "Alice"
file    = "feed-b/2.0.0.lua"
"#;
        let dir = setup_dir(
            toml,
            &[
                ("feed-a/1.0.0.lua", MINIMAL_SCRIPT),
                ("feed-b/2.0.0.lua", MINIMAL_SCRIPT),
            ],
        )
        .await;
        let registry = ScriptRegistry::load_entries(dir.path())
            .await
            .expect("load");

        assert_eq!(registry.len(), 2);
        assert!(registry.contains_key("feed-a"));
        let b = registry.get("feed-b").expect("feed-b");
        assert_eq!(b.author.as_deref(), Some("Alice"));
    }

    #[tokio::test]
    async fn load_empty_registry() {
        let dir = setup_dir("", &[]).await;
        let registry = ScriptRegistry::load_entries(dir.path())
            .await
            .expect("load");
        assert!(registry.is_empty());
    }

    #[tokio::test]
    async fn new_keeps_failed_entries_without_auto_delete() {
        let dir = tempfile::tempdir().expect("tempdir");
        ScriptRegistry::ensure_registry(dir.path())
            .await
            .expect("ensure registry");

        let mut entries = HashMap::new();
        entries.insert(
            "ok-feed".to_owned(),
            RegistryEntry {
                id: "ok-feed".to_owned(),
                name: "OK Feed".to_owned(),
                version: "1.0.0".to_owned(),
                author: None,
                file: "ok-feed/1.0.0.lua".to_owned(),
            },
        );
        entries.insert(
            "bad-feed".to_owned(),
            RegistryEntry {
                id: "bad-feed".to_owned(),
                name: "Bad Feed".to_owned(),
                version: "1.0.0".to_owned(),
                author: None,
                file: "bad-feed/1.0.0.lua".to_owned(),
            },
        );

        let mut feeds = HashMap::new();
        feeds.insert(
            "ok-feed".to_owned(),
            compile_feed(&make_valid_script("ok-feed", "1.0.0")).await,
        );

        let registry = ScriptRegistry::new(dir.path(), entries, feeds).expect("create registry");

        assert_eq!(registry.len(), 2);
        assert_eq!(registry.ready_len(), 1);
        assert!(registry.has_entry("ok-feed"));
        assert!(registry.has_entry("bad-feed"));
        assert!(registry.has_feed("ok-feed"));
        assert!(!registry.has_feed("bad-feed"));
        assert!(registry.feed("ok-feed").is_some());
        assert!(registry.feed("bad-feed").is_none());

        registry
            .persist_registry()
            .await
            .expect("persist registry with failed entry");

        let persisted = ScriptRegistry::load_entries(dir.path())
            .await
            .expect("reload registry file");
        assert!(persisted.contains_key("ok-feed"));
        assert!(persisted.contains_key("bad-feed"));
    }

    // -----------------------------------------------------------------------
    // load: duplicate id detection
    // -----------------------------------------------------------------------

    #[tokio::test]
    async fn load_duplicate_id_returns_error() {
        let toml = r#"
[[feeds]]
id      = "dup"
name    = "First"
version = "1.0.0"
file    = "dup/1.0.0.lua"

[[feeds]]
id      = "dup"
name    = "Second"
version = "2.0.0"
file    = "dup/2.0.0.lua"
"#;
        let dir = setup_dir(toml, &[]).await;
        let err = ScriptRegistry::load_entries(dir.path())
            .await
            .expect_err("should fail");
        assert!(
            matches!(err, Error::DuplicateFeedId { ref id } if id == "dup"),
            "unexpected error: {err}"
        );
    }

    // -----------------------------------------------------------------------
    // load: missing registry.toml
    // -----------------------------------------------------------------------

    #[tokio::test]
    async fn load_missing_registry_file() {
        let dir = tempfile::tempdir().expect("tempdir");
        let err = ScriptRegistry::load_entries(dir.path())
            .await
            .expect_err("should fail");
        assert!(
            matches!(err, Error::RegistryNotFound(_)),
            "unexpected error: {err}"
        );
    }

    // -----------------------------------------------------------------------
    // load: malformed TOML
    // -----------------------------------------------------------------------

    #[tokio::test]
    async fn load_malformed_toml() {
        let dir = setup_dir("this is not valid toml ][", &[]).await;
        let err = ScriptRegistry::load_entries(dir.path())
            .await
            .expect_err("should fail");
        assert!(
            matches!(err, Error::RegistryParse { .. }),
            "unexpected error: {err}"
        );
    }

    // -----------------------------------------------------------------------
    // install/remove: success and rollback behavior
    // -----------------------------------------------------------------------

    #[tokio::test]
    async fn install_feed_updates_memory_and_registry_file() {
        let dir = tempfile::tempdir().expect("tempdir");
        ScriptRegistry::ensure_registry(dir.path())
            .await
            .expect("ensure registry");

        let script = make_valid_script("installed-feed", "1.2.3");
        let engine = ScriptEngine::new();

        let mut registry = ScriptRegistry::new(dir.path(), HashMap::new(), HashMap::new())
            .expect("create empty registry");

        let entry = registry
            .install_feed(&script, &engine)
            .await
            .expect("install feed");

        assert_eq!(entry.id, "installed-feed");
        assert_eq!(entry.version, "1.2.3");
        assert!(registry.has_feed("installed-feed"));
        assert!(registry.feed("installed-feed").is_some());

        let persisted = ScriptRegistry::load_entries(dir.path())
            .await
            .expect("load persisted registry");
        let persisted_entry = persisted
            .get("installed-feed")
            .expect("persisted installed-feed");
        assert_eq!(persisted_entry.version, "1.2.3");

        let script_path = dir.path().join("installed-feed/1.2.3.lua");
        assert!(script_path.exists(), "installed script file should exist");
    }

    #[tokio::test]
    async fn install_feed_persist_failure_rolls_back_memory_and_file() {
        let dir = tempfile::tempdir().expect("tempdir");
        let bad_registry_path = dir.path().join("registry.toml");
        fs::create_dir_all(&bad_registry_path)
            .await
            .expect("create directory at registry.toml path");

        let script = make_valid_script("rollback-feed", "9.9.9");
        let engine = ScriptEngine::new();

        let mut registry = ScriptRegistry::new(dir.path(), HashMap::new(), HashMap::new())
            .expect("create empty registry");

        let err = registry
            .install_feed(&script, &engine)
            .await
            .expect_err("install should fail when registry persist fails");
        assert!(matches!(err, Error::RegistryWrite(_)));

        assert!(
            !registry.has_feed("rollback-feed"),
            "in-memory feed should be rolled back"
        );
        let script_path = dir.path().join("rollback-feed/9.9.9.lua");
        assert!(
            !script_path.exists(),
            "script file should be cleaned up on rollback"
        );
    }

    #[tokio::test]
    async fn install_feed_load_failure_rolls_back_memory_and_file() {
        let dir = tempfile::tempdir().expect("tempdir");
        ScriptRegistry::ensure_registry(dir.path())
            .await
            .expect("ensure registry");

        let invalid_script = r#"-- ==Feed==
-- @id      bad-feed
-- @name    Bad Feed
-- @version 1.0.0
-- @base_url https://example.com
-- ==/Feed==
return {}
"#;

        let engine = ScriptEngine::new();
        let mut registry = ScriptRegistry::new(dir.path(), HashMap::new(), HashMap::new())
            .expect("create empty registry");

        let err = registry
            .install_feed(invalid_script, &engine)
            .await
            .expect_err("install should fail when feed loading fails");
        assert!(matches!(err, Error::Lua(_)));
        assert!(!registry.has_feed("bad-feed"));

        let script_path = dir.path().join("bad-feed/1.0.0.lua");
        assert!(
            !script_path.exists(),
            "script file should be removed on load failure"
        );

        let persisted = ScriptRegistry::load_entries(dir.path())
            .await
            .expect("load persisted registry");
        assert!(
            !persisted.contains_key("bad-feed"),
            "registry.toml should not include failed feed"
        );
    }

    #[tokio::test]
    async fn remove_feed_success_removes_memory_registry_and_file() {
        let dir = tempfile::tempdir().expect("tempdir");
        ScriptRegistry::ensure_registry(dir.path())
            .await
            .expect("ensure registry");

        let mut registry = create_registry_with_single_feed(dir.path(), "remove-me", "1.0.0").await;
        registry
            .persist_registry()
            .await
            .expect("persist initial registry");

        let script_path = dir.path().join("remove-me/1.0.0.lua");
        assert!(script_path.exists(), "precondition: script file exists");

        registry
            .remove_feed("remove-me")
            .await
            .expect("remove feed");

        assert!(!registry.has_feed("remove-me"));
        assert!(!script_path.exists(), "script file should be deleted");

        let persisted = ScriptRegistry::load_entries(dir.path())
            .await
            .expect("reload registry file");
        assert!(
            !persisted.contains_key("remove-me"),
            "registry.toml should no longer contain removed feed"
        );
    }

    #[tokio::test]
    async fn remove_feed_file_delete_failure_rolls_back_memory_and_registry() {
        let dir = tempfile::tempdir().expect("tempdir");
        ScriptRegistry::ensure_registry(dir.path())
            .await
            .expect("ensure registry");

        let mut registry = create_registry_with_single_feed(dir.path(), "rollback-remove", "1.0.0").await;
        registry
            .persist_registry()
            .await
            .expect("persist initial registry");

        // Force remove_file to fail with a non-NotFound error by replacing the
        // script file with a directory.
        let script_path = dir.path().join("rollback-remove/1.0.0.lua");
        fs::remove_file(&script_path)
            .await
            .expect("remove existing script file");
        fs::create_dir_all(&script_path)
            .await
            .expect("create directory at script path");

        let err = registry
            .remove_feed("rollback-remove")
            .await
            .expect_err("remove should fail when deleting script path fails");
        assert!(matches!(err, Error::RegistryWrite(_)));

        assert!(
            registry.has_feed("rollback-remove"),
            "in-memory feed should be restored on rollback"
        );

        let persisted = ScriptRegistry::load_entries(dir.path())
            .await
            .expect("reload registry file");
        assert!(
            persisted.contains_key("rollback-remove"),
            "registry.toml should be restored on rollback"
        );
    }
}

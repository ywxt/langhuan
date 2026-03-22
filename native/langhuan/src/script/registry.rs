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

use serde::Deserialize;

use crate::error::{Error, Result};

// ---------------------------------------------------------------------------
// TOML data structures
// ---------------------------------------------------------------------------

/// A single entry in `registry.toml`.
#[derive(Debug, Clone, Deserialize)]
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
#[derive(Debug, Deserialize)]
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
#[derive(Debug)]
pub struct ScriptRegistry {
    base_dir: PathBuf,
    entries: HashMap<String, RegistryEntry>,
}

impl ScriptRegistry {
    /// Load the registry from `<base_dir>/registry.toml`.
    ///
    /// # Errors
    /// - [`Error::RegistryNotFound`] — the file cannot be read.
    /// - [`Error::RegistryParse`] — the TOML is malformed.
    /// - [`Error::DuplicateFeedId`] — two entries share the same `id`.
    pub async fn load(base_dir: &Path) -> Result<Self> {
        let registry_path = base_dir.join("registry.toml");

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

        Ok(Self {
            base_dir: base_dir.to_owned(),
            entries,
        })
    }

    /// Read and return the full Lua script source for the given `feed_id`.
    ///
    /// # Errors
    /// - [`Error::FeedNotFound`] — `feed_id` is not in the registry.
    /// - [`Error::RegistryNotFound`] — the script file cannot be read.
    pub async fn get_script(&self, feed_id: &str) -> Result<String> {
        let entry = self.entries.get(feed_id).ok_or_else(|| Error::FeedNotFound {
            id: feed_id.to_owned(),
        })?;

        let script_path = self.base_dir.join(&entry.file);
        let script = tokio::fs::read_to_string(&script_path)
            .await
            .map_err(Error::RegistryNotFound)?;

        Ok(script)
    }

    /// Iterate over all registered feed entries.
    pub fn list_entries(&self) -> impl Iterator<Item = &RegistryEntry> {
        self.entries.values()
    }

    /// Return the number of registered feeds.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Return `true` if no feeds are registered.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use tempfile::TempDir;
    use tokio::fs;

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
        let registry = ScriptRegistry::load(dir.path()).await.expect("load");

        assert_eq!(registry.len(), 1);
        let entry = registry.entries.get("test-feed").expect("entry");
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
        let registry = ScriptRegistry::load(dir.path()).await.expect("load");

        assert_eq!(registry.len(), 2);
        assert!(registry.entries.contains_key("feed-a"));
        let b = registry.entries.get("feed-b").expect("feed-b");
        assert_eq!(b.author.as_deref(), Some("Alice"));
    }

    #[tokio::test]
    async fn load_empty_registry() {
        let dir = setup_dir("", &[]).await;
        let registry = ScriptRegistry::load(dir.path()).await.expect("load");
        assert!(registry.is_empty());
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
        let err = ScriptRegistry::load(dir.path()).await.expect_err("should fail");
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
        let err = ScriptRegistry::load(dir.path()).await.expect_err("should fail");
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
        let err = ScriptRegistry::load(dir.path()).await.expect_err("should fail");
        assert!(
            matches!(err, Error::RegistryParse { .. }),
            "unexpected error: {err}"
        );
    }

    // -----------------------------------------------------------------------
    // get_script: happy path
    // -----------------------------------------------------------------------

    #[tokio::test]
    async fn get_script_returns_content() {
        let toml = r#"
[[feeds]]
id      = "test-feed"
name    = "Test"
version = "1.0.0"
file    = "test-feed/1.0.0.lua"
"#;
        let dir = setup_dir(toml, &[("test-feed/1.0.0.lua", MINIMAL_SCRIPT)]).await;
        let registry = ScriptRegistry::load(dir.path()).await.expect("load");

        let script = registry.get_script("test-feed").await.expect("get_script");
        assert!(script.contains("@id"), "script content should contain header");
    }

    // -----------------------------------------------------------------------
    // get_script: unknown feed id
    // -----------------------------------------------------------------------

    #[tokio::test]
    async fn get_script_unknown_id() {
        let dir = setup_dir("", &[]).await;
        let registry = ScriptRegistry::load(dir.path()).await.expect("load");
        let err = registry
            .get_script("nonexistent")
            .await
            .expect_err("should fail");
        assert!(
            matches!(err, Error::FeedNotFound { ref id } if id == "nonexistent"),
            "unexpected error: {err}"
        );
    }

    // -----------------------------------------------------------------------
    // list_entries
    // -----------------------------------------------------------------------

    #[tokio::test]
    async fn list_entries_returns_all() {
        let toml = r#"
[[feeds]]
id = "a"
name = "A"
version = "1.0.0"
file = "a/1.0.0.lua"

[[feeds]]
id = "b"
name = "B"
version = "1.0.0"
file = "b/1.0.0.lua"
"#;
        let dir = setup_dir(toml, &[]).await;
        let registry = ScriptRegistry::load(dir.path()).await.expect("load");
        let mut ids: Vec<&str> = registry.list_entries().map(|e| e.id.as_str()).collect();
        ids.sort();
        assert_eq!(ids, ["a", "b"]);
    }
}

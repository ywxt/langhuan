//! [`RegistryActor`] — manages the feed registry and script installation.
//!
//! Installed feeds live in the `feeds` / `feed_scripts` tables; this actor
//! compiles the scripts into [`ScriptFeed`] instances at startup and keeps them
//! in memory. Compilation results and pending (previewed, not installed)
//! scripts are the only in-memory state.

use std::collections::HashMap;
use std::fmt;
use std::sync::Arc;

use async_trait::async_trait;

use langhuan::cache::CachedFeed;
use langhuan::db::Db;
use langhuan::db::repo::FeedRow;
use langhuan::feed::FeedMeta;
use langhuan::script::feed::ScriptFeed;
use langhuan::script::runtime::ScriptEngine;
use messages::prelude::{Actor, Address, Context, Handler};

use crate::api::types::{
    BridgeError, FeedImportFailure, FeedImportOutcome, FeedMetaItem, FeedPreviewInfo, VersionChange,
};
use crate::localize_error;

use super::app_data_actor::InitializeAppDataDirectory;
use super::webview_actor::{WebviewActor, attach_webview_handler};

/// How many script versions are kept per feed.
const SCRIPT_HISTORY_KEEP: usize = langhuan::db::maintenance::SCRIPT_HISTORY_KEEP;

/// Previewed-but-not-installed scripts remembered for `InstallFeed`.
const PENDING_INSTALLS_CAP: usize = 8;

pub struct RegistryInitializationResult {
    pub feed_count: u32,
}

// ---------------------------------------------------------------------------
// ResolveError
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub enum ResolveError {
    DirNotSet,
    Unavailable { id: String },
    NotFound { id: String },
}

impl fmt::Display for ResolveError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ResolveError::DirNotSet => write!(f, "{}", t!("error.app_data_dir_not_set")),
            ResolveError::Unavailable { id } => {
                write!(f, "{}", t!("error.feed_unavailable", id = id))
            }
            ResolveError::NotFound { id } => {
                write!(f, "{}", t!("error.feed_not_found", id = id))
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Actor-to-actor messages
// ---------------------------------------------------------------------------

pub struct GetFeed {
    pub feed_id: String,
}

pub struct GetFeedIds;

// ---------------------------------------------------------------------------
// FRB-facing messages
// ---------------------------------------------------------------------------

pub struct ListFeeds;

pub struct PreviewFeedFromUrl {
    pub url: String,
}

pub struct PreviewFeedFromFile {
    pub path: String,
}

pub struct InstallFeed {
    pub request_id: String,
}

pub struct RemoveFeed {
    pub feed_id: String,
}

pub struct SetFeedEnabled {
    pub feed_id: String,
    pub enabled: bool,
}

/// One script of a bulk import. The script content is the source of truth;
/// `source_url` is carried separately because it is registry state, not
/// script metadata.
pub struct ImportFeedScript {
    pub script: String,
    pub source_url: Option<String>,
}

/// Bulk-install scripts (feed import). Installs each entry independently;
/// failures are collected per entry instead of failing the whole import.
pub struct ImportFeeds {
    pub entries: Vec<ImportFeedScript>,
}

// ---------------------------------------------------------------------------
// Pending installs
// ---------------------------------------------------------------------------

/// A previewed script waiting for `InstallFeed`, keyed by feed id.
struct PendingInstall {
    content: String,
    source_url: Option<String>,
    /// Monotonic insertion counter for LRU eviction.
    seq: u64,
}

// ---------------------------------------------------------------------------
// RegistryActor
// ---------------------------------------------------------------------------

pub struct RegistryActor {
    engine: ScriptEngine,
    webview_addr: Address<WebviewActor>,
    db: Option<Db>,
    /// Successfully compiled feeds, keyed by feed id.
    feeds: HashMap<String, Arc<ScriptFeed>>,
    /// Registered feeds whose script failed to compile (id → user-facing
    /// message). Kept so `ListFeeds` can surface the failure and `GetFeed`
    /// can distinguish "registered but broken" from "unknown".
    load_errors: HashMap<String, String>,
    pending_installs: HashMap<String, PendingInstall>,
    pending_seq: u64,
}

impl Actor for RegistryActor {}

impl RegistryActor {
    pub fn new(engine: ScriptEngine, webview_addr: Address<WebviewActor>) -> Self {
        Self {
            engine,
            webview_addr,
            db: None,
            feeds: HashMap::new(),
            load_errors: HashMap::new(),
            pending_installs: HashMap::new(),
            pending_seq: 0,
        }
    }

    /// Compile a script into a feed with the hub's webview handler attached,
    /// so its reducers can request interactive verification.
    async fn compile_feed(&self, script: &str) -> Result<ScriptFeed, langhuan::error::Error> {
        let feed = self.engine.load_script(script).await?;
        attach_webview_handler(&feed, &self.webview_addr)?;
        Ok(feed)
    }

    // -----------------------------------------------------------------------
    // Business logic
    // -----------------------------------------------------------------------

    async fn initialize_app_data_directory(
        &mut self,
        db: Db,
    ) -> Result<RegistryInitializationResult, String> {
        tracing::info!("initializing registry actor from database");
        if self.db.is_some() {
            return Err(t!("error.registry_reload_not_supported").to_string());
        }

        let rows = db
            .call(|repo| repo.list_feeds_with_scripts())
            .await
            .map_err(|e| localize_error(&e))?;

        let mut feeds = HashMap::new();
        let mut load_errors: HashMap<String, String> = HashMap::new();

        for (row, script) in rows {
            let Some(script) = script else {
                load_errors.insert(
                    row.id.clone(),
                    t!("error.feed_script_missing", id = row.id.as_str()).to_string(),
                );
                continue;
            };
            match self.compile_feed(&script).await {
                Err(e) => {
                    load_errors.insert(row.id.clone(), localize_error(&e));
                }
                Ok(feed) => {
                    feeds.insert(row.id.clone(), Arc::new(feed));
                }
            }
        }

        let feed_count = feeds.len() as u32;
        let load_error_count = load_errors.len();

        self.db = Some(db);
        self.feeds = feeds;
        self.load_errors = load_errors;
        tracing::info!(feed_count, load_error_count, "registry actor initialized");

        Ok(RegistryInitializationResult { feed_count })
    }

    fn require_db(&self) -> Result<&Db, BridgeError> {
        self.db
            .as_ref()
            .ok_or_else(|| BridgeError::from(t!("error.app_data_dir_not_set").to_string()))
    }

    async fn do_list_feeds(&self) -> Vec<FeedMetaItem> {
        let Some(db) = &self.db else {
            return vec![];
        };
        let rows = match db.call(|repo| repo.list_feeds()).await {
            Ok(rows) => rows,
            Err(e) => {
                tracing::warn!(error = %e, "failed to list feeds from database");
                return vec![];
            }
        };
        // The database is the source of truth: script metadata was cached
        // into the row at install time and is never re-derived here, so a
        // feed with a broken script still lists its base URL and domains.
        rows.into_iter()
            .map(|row| FeedMetaItem {
                error: self.load_errors.get(&row.id).cloned(),
                ..row.into()
            })
            .collect()
    }

    async fn do_preview_from_url(&mut self, url: String) -> Result<FeedPreviewInfo, BridgeError> {
        tracing::debug!(url = %url, "preview feed from url");
        let content = langhuan::script::source::download_script(&url).await?;
        self.do_preview(content, Some(url)).await
    }

    async fn do_preview_from_file(&mut self, path: String) -> Result<FeedPreviewInfo, BridgeError> {
        tracing::debug!(path = %path, "preview feed from file");
        let content = tokio::fs::read_to_string(&path).await.map_err(|e| {
            BridgeError::from(t!("error.file_read", error = e.to_string()).to_string())
        })?;
        self.do_preview(content, None).await
    }

    /// Parse `content`, remember it as a pending install, and return preview
    /// info. The feed id doubles as the `request_id` for `InstallFeed`.
    async fn do_preview(
        &mut self,
        content: String,
        source_url: Option<String>,
    ) -> Result<FeedPreviewInfo, BridgeError> {
        let (meta, _) = langhuan::script::meta::parse_meta(&content)?;

        let current_version = match &self.db {
            None => None,
            Some(db) => {
                let id = meta.id.clone();
                db.call(move |conn| Ok(conn.get_feed(&id)?.map(|row| row.version)))
                    .await?
            }
        };
        let version_change = classify_version_change(current_version.as_deref(), &meta.version);

        self.push_pending(
            meta.id.clone(),
            PendingInstall {
                content,
                source_url,
                seq: 0,
            },
        );

        Ok(FeedPreviewInfo {
            id: meta.id,
            name: meta.name,
            version: meta.version,
            author: meta.author,
            description: meta.description,
            base_url: meta.base_url,
            access_domains: meta.access_domains,
            current_version,
            version_change,
            schema_version: meta.schema_version,
        })
    }

    /// Insert a pending install, evicting the oldest preview when the cap is
    /// reached (re-previewing the same feed id replaces in place).
    fn push_pending(&mut self, feed_id: String, mut install: PendingInstall) {
        if !self.pending_installs.contains_key(&feed_id)
            && self.pending_installs.len() >= PENDING_INSTALLS_CAP
            && let Some(oldest) = self
                .pending_installs
                .iter()
                .min_by_key(|(_, pending)| pending.seq)
                .map(|(id, _)| id.clone())
        {
            tracing::debug!(feed_id = %oldest, "evicting stale pending preview");
            self.pending_installs.remove(&oldest);
        }
        self.pending_seq += 1;
        install.seq = self.pending_seq;
        self.pending_installs.insert(feed_id, install);
    }

    async fn do_install(&mut self, request_id: String) -> Result<(), BridgeError> {
        tracing::debug!(request_id = %request_id, "install feed");
        let pending = self
            .pending_installs
            .remove(&request_id)
            .ok_or_else(|| BridgeError::from(t!("error.no_pending_preview").to_string()))?;
        let db = self.require_db()?;

        // Compile first — a script that cannot run is never persisted.
        let (meta, _) = langhuan::script::meta::parse_meta(&pending.content)?;
        let feed = self.compile_feed(&pending.content).await?;

        let content_hash = langhuan::hash::sha256_hex(pending.content.as_bytes());
        let now = langhuan::db::now_ms();
        db.write({
            let meta = meta.clone();
            let content = pending.content;
            let source_url = pending.source_url;
            let content_hash = content_hash.clone();
            move |conn| {
                conn.upsert_feed(&meta, source_url.as_deref(), &content_hash, now)?;
                conn.upsert_script(&meta.id, &meta.version, &content_hash, &content, now)?;
                conn.prune_scripts(&meta.id, SCRIPT_HISTORY_KEEP)?;
                Ok(())
            }
        })
        .await?;

        self.feeds.insert(meta.id.clone(), Arc::new(feed));
        self.load_errors.remove(&meta.id);
        tracing::info!(feed_id = %meta.id, version = %meta.version, "feed installed");
        Ok(())
    }

    /// Install one imported script. Returns `Ok(false)` when the exact
    /// version and content are already installed (a skip, not an error).
    async fn install_imported(
        &mut self,
        meta: FeedMeta,
        content: String,
        source_url: Option<String>,
    ) -> Result<bool, BridgeError> {
        let db = self.require_db()?;

        // Compile first — a script that cannot run is never persisted.
        let feed = self.compile_feed(&content).await?;

        let content_hash = langhuan::hash::sha256_hex(content.as_bytes());
        let already_installed = db
            .call({
                let id = meta.id.clone();
                move |repo| repo.get_feed(&id)
            })
            .await?
            .is_some_and(|row| row.version == meta.version && row.content_hash == content_hash);
        if already_installed {
            return Ok(false);
        }

        let now = langhuan::db::now_ms();
        db.write({
            let meta = meta.clone();
            move |conn| {
                conn.upsert_feed(&meta, source_url.as_deref(), &content_hash, now)?;
                conn.upsert_script(&meta.id, &meta.version, &content_hash, &content, now)?;
                conn.prune_scripts(&meta.id, SCRIPT_HISTORY_KEEP)?;
                Ok(())
            }
        })
        .await?;

        self.feeds.insert(meta.id.clone(), Arc::new(feed));
        self.load_errors.remove(&meta.id);
        tracing::info!(feed_id = %meta.id, version = %meta.version, "feed imported");
        Ok(true)
    }

    /// Bulk-import scripts: each entry installs (or skips) independently,
    /// and failures are collected per entry.
    async fn do_import(
        &mut self,
        entries: Vec<ImportFeedScript>,
    ) -> Result<FeedImportOutcome, BridgeError> {
        tracing::debug!(count = entries.len(), "import feeds");
        let mut outcome = FeedImportOutcome {
            installed: 0,
            skipped: 0,
            failed: Vec::new(),
        };

        for entry in entries {
            // Parse first so failures carry the feed id when it is known.
            let meta = match langhuan::script::meta::parse_meta(&entry.script) {
                Ok((meta, _)) => meta,
                Err(e) => {
                    outcome.failed.push(FeedImportFailure {
                        id: String::new(),
                        error: BridgeError::from(e).message,
                    });
                    continue;
                }
            };
            let feed_id = meta.id.clone();
            match self
                .install_imported(meta, entry.script, entry.source_url)
                .await
            {
                Ok(true) => outcome.installed += 1,
                Ok(false) => outcome.skipped += 1,
                Err(e) => outcome.failed.push(FeedImportFailure {
                    id: feed_id,
                    error: e.message,
                }),
            }
        }

        tracing::info!(
            installed = outcome.installed,
            skipped = outcome.skipped,
            failed = outcome.failed.len(),
            "feed import complete"
        );
        Ok(outcome)
    }

    async fn do_remove(&mut self, feed_id: String) -> Result<(), BridgeError> {
        tracing::debug!(feed_id = %feed_id, "remove feed");
        let db = self.require_db()?;

        // One transaction: the schema cascades books (→ cache, covers,
        // bookshelf), progress, bookmarks, and auth rows.
        let removed = db
            .write({
                let feed_id = feed_id.clone();
                move |repo| repo.delete_feed(&feed_id)
            })
            .await?;
        if !removed {
            return Err(BridgeError::from(langhuan::error::Error::feed_not_found(
                feed_id,
            )));
        }

        self.feeds.remove(&feed_id);
        self.load_errors.remove(&feed_id);
        Ok(())
    }

    /// Pause or resume a feed. The compiled feed and its cached state are
    /// untouched — enabling only re-includes the feed in aggregated search
    /// and background update checks.
    async fn do_set_enabled(&self, feed_id: String, enabled: bool) -> Result<(), BridgeError> {
        tracing::debug!(feed_id = %feed_id, enabled, "set feed enabled");
        let db = self.require_db()?;

        let updated = db
            .write({
                let feed_id = feed_id.clone();
                move |repo| repo.set_feed_enabled(&feed_id, enabled)
            })
            .await?;
        if !updated {
            return Err(BridgeError::from(langhuan::error::Error::feed_not_found(
                feed_id,
            )));
        }
        Ok(())
    }
}

/// Compare the installed version with the previewed one.
pub(crate) fn classify_version_change(current: Option<&str>, new: &str) -> VersionChange {
    let Some(current) = current else {
        return VersionChange::New;
    };
    match (semver::Version::parse(current), semver::Version::parse(new)) {
        (Ok(current), Ok(new)) if new > current => VersionChange::Upgrade,
        (Ok(current), Ok(new)) if new < current => VersionChange::Downgrade,
        (Ok(_), Ok(_)) => VersionChange::Same,
        _ => VersionChange::Unknown,
    }
}

/// Map a stored feed row to its bridge representation.
///
/// Every field comes from the database — script metadata was cached at
/// install time — except `error`, which is actor state (the script failed
/// to compile this session) and is overwritten by the caller.
impl From<FeedRow> for FeedMetaItem {
    fn from(row: FeedRow) -> Self {
        FeedMetaItem {
            id: row.id,
            name: row.name,
            version: row.version,
            author: row.author,
            enabled: row.enabled,
            source_url: row.source_url,
            base_url: row.base_url,
            access_domains: row.access_domains,
            description: row.description,
            error: None,
        }
    }
}

// ---------------------------------------------------------------------------
// Handler impls — actor-to-actor
// ---------------------------------------------------------------------------

#[async_trait]
impl Handler<GetFeed> for RegistryActor {
    type Result = Result<Arc<CachedFeed<ScriptFeed>>, ResolveError>;

    async fn handle(&mut self, msg: GetFeed, _: &Context<Self>) -> Self::Result {
        let db = self.db.as_ref().ok_or(ResolveError::DirNotSet)?;

        if let Some(feed) = self.feeds.get(&msg.feed_id) {
            return Ok(Arc::new(CachedFeed::new(Arc::clone(feed), db.clone())));
        }

        if self.load_errors.contains_key(&msg.feed_id) {
            Err(ResolveError::Unavailable { id: msg.feed_id })
        } else {
            Err(ResolveError::NotFound { id: msg.feed_id })
        }
    }
}

#[async_trait]
impl Handler<GetFeedIds> for RegistryActor {
    type Result = Result<Vec<String>, ResolveError>;

    async fn handle(&mut self, _: GetFeedIds, _: &Context<Self>) -> Self::Result {
        if self.db.is_none() {
            return Err(ResolveError::DirNotSet);
        }
        // Only successfully compiled feeds — consumers (auth hydration)
        // cannot use broken ones anyway.
        Ok(self.feeds.keys().cloned().collect())
    }
}

// ---------------------------------------------------------------------------
// Handler impls — FRB-facing
// ---------------------------------------------------------------------------

#[async_trait]
impl Handler<InitializeAppDataDirectory> for RegistryActor {
    type Result = Result<RegistryInitializationResult, String>;

    async fn handle(&mut self, msg: InitializeAppDataDirectory, _: &Context<Self>) -> Self::Result {
        self.initialize_app_data_directory(msg.db).await
    }
}

#[async_trait]
impl Handler<ListFeeds> for RegistryActor {
    type Result = Vec<FeedMetaItem>;

    async fn handle(&mut self, _: ListFeeds, _: &Context<Self>) -> Self::Result {
        self.do_list_feeds().await
    }
}

#[async_trait]
impl Handler<PreviewFeedFromUrl> for RegistryActor {
    type Result = Result<FeedPreviewInfo, BridgeError>;

    async fn handle(&mut self, msg: PreviewFeedFromUrl, _: &Context<Self>) -> Self::Result {
        self.do_preview_from_url(msg.url).await
    }
}

#[async_trait]
impl Handler<PreviewFeedFromFile> for RegistryActor {
    type Result = Result<FeedPreviewInfo, BridgeError>;

    async fn handle(&mut self, msg: PreviewFeedFromFile, _: &Context<Self>) -> Self::Result {
        self.do_preview_from_file(msg.path).await
    }
}

#[async_trait]
impl Handler<InstallFeed> for RegistryActor {
    type Result = Result<(), BridgeError>;

    async fn handle(&mut self, msg: InstallFeed, _: &Context<Self>) -> Self::Result {
        self.do_install(msg.request_id).await
    }
}

#[async_trait]
impl Handler<RemoveFeed> for RegistryActor {
    type Result = Result<(), BridgeError>;

    async fn handle(&mut self, msg: RemoveFeed, _: &Context<Self>) -> Self::Result {
        self.do_remove(msg.feed_id).await
    }
}

#[async_trait]
impl Handler<SetFeedEnabled> for RegistryActor {
    type Result = Result<(), BridgeError>;

    async fn handle(&mut self, msg: SetFeedEnabled, _: &Context<Self>) -> Self::Result {
        self.do_set_enabled(msg.feed_id, msg.enabled).await
    }
}

#[async_trait]
impl Handler<ImportFeeds> for RegistryActor {
    type Result = Result<FeedImportOutcome, BridgeError>;

    async fn handle(&mut self, msg: ImportFeeds, _: &Context<Self>) -> Self::Result {
        self.do_import(msg.entries).await
    }
}

#[cfg(test)]
mod tests {
    use std::error::Error;

    use langhuan::db::Db;
    use langhuan::script::runtime::ScriptEngine;

    use super::*;

    type TestResult = Result<(), Box<dyn Error>>;

    /// Spawns an idle WebviewActor and hands back its address — the tests
    /// never prompt, but every compiled feed needs a handler target.
    fn webview_address() -> Address<WebviewActor> {
        let context = Context::new();
        let address = context.address();
        tokio::spawn(context.run(WebviewActor::new()));
        address
    }

    #[test]
    fn version_change_classification() {
        use VersionChange::*;
        assert_eq!(classify_version_change(None, "1.0.0"), New);
        assert_eq!(classify_version_change(Some("1.0.0"), "1.1.0"), Upgrade);
        assert_eq!(classify_version_change(Some("1.2.0"), "1.1.0"), Downgrade);
        assert_eq!(classify_version_change(Some("1.0.0"), "1.0.0"), Same);
        assert_eq!(classify_version_change(Some("latest"), "1.0.0"), Unknown);
        assert_eq!(classify_version_change(Some("1.0.0"), "latest"), Unknown);
    }

    /// A minimal but valid feed script: all four required handlers, all
    /// no-ops (the import only checks that the script compiles).
    fn import_script(id: &str, version: &str) -> String {
        format!(
            r#"// ==Feed==
// @id  {id}
// @name Feed {id}
// @version {version}
// @schema_version 3
// @base_url http://127.0.0.1:1/
// @access_domain 127.0.0.1
// ==/Feed==
(() => {{
  const empty = () => ({{ type: "complete", items: [] }});
  const bookInfo = () => ({{
    type: "complete",
    value: {{ id: "0", title: "", author: "" }},
  }});
  return {{ search: empty, bookInfo, chapters: empty, paragraphs: empty }};
}})()
"#
        )
    }

    #[tokio::test]
    async fn import_installs_skips_and_collects_failures() -> TestResult {
        let db = Db::open_in_memory().await?;

        // Pre-install f1 exactly as the import will carry it, so that
        // entry skips (same version AND content).
        let f1 = import_script("f1", "1.0.0");
        let (meta, _) = langhuan::script::meta::parse_meta(&f1)?;
        let hash = langhuan::hash::sha256_hex(f1.as_bytes());
        db.write({
            let script = f1.clone();
            move |repo| {
                repo.upsert_feed(&meta, None, &hash, 1)?;
                repo.upsert_script("f1", "1.0.0", &hash, &script, 1)
            }
        })
        .await?;

        let mut actor = RegistryActor::new(ScriptEngine::new(), webview_address());
        actor.initialize_app_data_directory(db.clone()).await?;

        let f2 = import_script("f2", "1.0.0");
        let outcome = actor
            .do_import(vec![
                ImportFeedScript {
                    script: f1.clone(),
                    source_url: None,
                },
                ImportFeedScript {
                    script: f2.clone(),
                    source_url: Some("https://example.com/src".to_owned()),
                },
                ImportFeedScript {
                    script: "// ==Feed==\n// no metadata at all\n// ==/Feed==\n({})".to_owned(),
                    source_url: None,
                },
            ])
            .await?;

        assert_eq!(outcome.installed, 1, "the new feed installs");
        assert_eq!(outcome.skipped, 1, "the identical feed skips");
        assert_eq!(outcome.failed.len(), 1, "the unparseable feed fails alone");
        assert_eq!(outcome.failed[0].id, "");

        // The installed feed is compiled, registered and persisted with
        // its source_url.
        assert!(actor.feeds.contains_key("f2"));
        let rows = db.call(|repo| repo.list_feeds()).await?;
        let f2_row = rows.iter().find(|row| row.id == "f2").expect("f2 row");
        assert_eq!(
            f2_row.source_url.as_deref(),
            Some("https://example.com/src")
        );

        // Listed metadata comes from the database: the import flow cached
        // the script's base URL and access domains into the row.
        let items = actor.do_list_feeds().await;
        let f2_item = items.iter().find(|item| item.id == "f2").expect("f2 item");
        assert_eq!(f2_item.base_url.as_deref(), Some("http://127.0.0.1:1/"));
        assert_eq!(f2_item.access_domains, vec!["127.0.0.1".to_owned()]);
        assert_eq!(
            f2_item.source_url.as_deref(),
            Some("https://example.com/src")
        );

        // Re-importing the same set: nothing new installs, both valid
        // entries skip, the broken one keeps failing.
        let outcome = actor
            .do_import(vec![
                ImportFeedScript {
                    script: f1,
                    source_url: None,
                },
                ImportFeedScript {
                    script: f2,
                    source_url: None,
                },
            ])
            .await?;
        assert_eq!(outcome.installed, 0);
        assert_eq!(outcome.skipped, 2);
        Ok(())
    }

    #[tokio::test]
    async fn initialize_loads_feeds_from_database() -> TestResult {
        let db = Db::open_in_memory().await?;
        // Seed one feed directly through the repo layer.
        let meta = langhuan::feed::FeedMeta {
            id: "f1".to_owned(),
            name: "Feed One".to_owned(),
            version: "1.0.0".to_owned(),
            author: None,
            description: Some("One extraordinary feed.".to_owned()),
            base_url: "https://example.com".to_owned(),
            access_domains: Default::default(),
            schema_version: 1,
        };
        db.write(move |repo| {
            repo.upsert_feed(&meta, None, "hash", 1)?;
            repo.upsert_script("f1", "1.0.0", "hash", "// not a feed", 1)
        })
        .await?;

        let mut actor = RegistryActor::new(ScriptEngine::new(), webview_address());
        let result = actor.initialize_app_data_directory(db).await?;
        // The seeded script fails to compile, but registration survives.
        assert_eq!(result.feed_count, 0);
        assert!(actor.load_errors.contains_key("f1"));

        // A broken script keeps its registry row and, because listing
        // reads the database rather than the compiled script, the
        // metadata cached at install time stays available.
        let items = actor.do_list_feeds().await;
        let broken = items.iter().find(|item| item.id == "f1").expect("f1 item");
        assert!(broken.error.is_some());
        assert_eq!(broken.base_url.as_deref(), Some("https://example.com"));
        assert!(broken.access_domains.is_empty());
        assert_eq!(
            broken.description.as_deref(),
            Some("One extraordinary feed.")
        );
        Ok(())
    }

    #[tokio::test]
    async fn pending_installs_are_capped_and_lru() {
        let mut actor = RegistryActor::new(ScriptEngine::new(), webview_address());
        for i in 0..PENDING_INSTALLS_CAP {
            actor.push_pending(
                format!("f{i}"),
                PendingInstall {
                    content: format!("-- {i}"),
                    source_url: None,
                    seq: 0,
                },
            );
        }
        assert_eq!(actor.pending_installs.len(), PENDING_INSTALLS_CAP);

        // Re-previewing an existing id replaces it in place and refreshes
        // its recency — nothing is evicted.
        actor.push_pending(
            "f0".to_owned(),
            PendingInstall {
                content: "-- again".to_owned(),
                source_url: None,
                seq: 0,
            },
        );
        assert_eq!(actor.pending_installs.len(), PENDING_INSTALLS_CAP);
        assert!(actor.pending_installs.contains_key("f0"));

        // A new id evicts the least-recently-previewed entry — that is f1,
        // since f0's re-preview just refreshed it.
        actor.push_pending(
            "new".to_owned(),
            PendingInstall {
                content: "-- new".to_owned(),
                source_url: None,
                seq: 0,
            },
        );
        assert_eq!(actor.pending_installs.len(), PENDING_INSTALLS_CAP);
        assert!(!actor.pending_installs.contains_key("f1"), "oldest evicted");
        assert!(actor.pending_installs.contains_key("f0"), "refreshed kept");
        assert!(actor.pending_installs.contains_key("new"));
    }
}

//! [`RegistryActor`] — manages the feed registry and script installation.
//!
//! Installed feeds live in the `feeds` / `feed_scripts` tables; this actor
//! compiles the scripts into [`LuaFeed`] instances at startup and keeps them
//! in memory. Compilation results and pending (previewed, not installed)
//! scripts are the only in-memory state.

use std::collections::HashMap;
use std::fmt;
use std::sync::Arc;

use async_trait::async_trait;

use langhuan::cache::CachedFeed;
use langhuan::db::repo::{FeedRow, FeedsRepo};
use langhuan::db::Db;
use langhuan::script::lua::LuaFeed;
use langhuan::script::runtime::ScriptEngine;
use messages::prelude::{Actor, Context, Handler};

use crate::api::types::{BridgeError, FeedMetaItem, FeedPreviewInfo, VersionChange};
use crate::localize_error;

use super::app_data_actor::InitializeAppDataDirectory;

/// How many script versions are kept per feed.
const SCRIPT_HISTORY_KEEP: usize = langhuan::db::maintenance::SCRIPT_HISTORY_KEEP;

/// Previewed-but-not-installed scripts remembered for `InstallFeed`.
const PENDING_INSTALLS_CAP: usize = 8;

pub struct RegistryInitializationResult {
    pub feed_count: u32,
    pub warning_message: Option<String>,
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
    db: Option<Db>,
    /// Successfully compiled feeds, keyed by feed id.
    feeds: HashMap<String, Arc<LuaFeed>>,
    /// Registered feeds whose script failed to compile (id → user-facing
    /// message). Kept so `ListFeeds` can surface the failure and `GetFeed`
    /// can distinguish "registered but broken" from "unknown".
    load_errors: HashMap<String, String>,
    pending_installs: HashMap<String, PendingInstall>,
    pending_seq: u64,
}

impl Actor for RegistryActor {}

impl RegistryActor {
    pub fn new(engine: ScriptEngine) -> Self {
        Self {
            engine,
            db: None,
            feeds: HashMap::new(),
            load_errors: HashMap::new(),
            pending_installs: HashMap::new(),
            pending_seq: 0,
        }
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
            .call(|conn| conn.list_feeds_with_scripts())
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
            match self.engine.load_feed(&script).await {
                Err(e) => {
                    load_errors.insert(row.id.clone(), localize_error(&e));
                }
                Ok(feed) => {
                    feeds.insert(row.id.clone(), Arc::new(feed));
                }
            }
        }

        let feed_count = feeds.len() as u32;
        let error_summary = if load_errors.is_empty() {
            None
        } else {
            Some(
                load_errors
                    .iter()
                    .map(|(id, e)| format!("{id}: {e}"))
                    .collect::<Vec<_>>()
                    .join("; "),
            )
        };

        self.db = Some(db);
        self.feeds = feeds;
        self.load_errors = load_errors;
        tracing::info!(feed_count = feed_count, "registry actor initialized");

        Ok(RegistryInitializationResult {
            feed_count,
            warning_message: error_summary,
        })
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
        let rows = match db.call(|conn| conn.list_feeds()).await {
            Ok(rows) => rows,
            Err(e) => {
                tracing::warn!(error = %e, "failed to list feeds from database");
                return vec![];
            }
        };
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
        let feed = self.engine.load_feed(&pending.content).await?;

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

    async fn do_remove(&mut self, feed_id: String) -> Result<(), BridgeError> {
        tracing::debug!(feed_id = %feed_id, "remove feed");
        let db = self.require_db()?;

        // One transaction: the schema cascades books (→ cache, covers,
        // bookshelf), progress, bookmarks, and auth rows.
        let removed = db
            .write({
                let feed_id = feed_id.clone();
                move |conn| conn.delete_feed(&feed_id)
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
}

/// Compare the installed version with the previewed one.
fn classify_version_change(current: Option<&str>, new: &str) -> VersionChange {
    let Some(current) = current else {
        return VersionChange::New;
    };
    match (
        semver::Version::parse(current),
        semver::Version::parse(new),
    ) {
        (Ok(current), Ok(new)) if new > current => VersionChange::Upgrade,
        (Ok(current), Ok(new)) if new < current => VersionChange::Downgrade,
        (Ok(_), Ok(_)) => VersionChange::Same,
        _ => VersionChange::Unknown,
    }
}

/// Map a stored feed row to its bridge representation.
///
/// The `error` field (script failed to compile) is actor state and is
/// overwritten by the caller after conversion.
impl From<FeedRow> for FeedMetaItem {
    fn from(row: FeedRow) -> Self {
        FeedMetaItem {
            id: row.id,
            name: row.name,
            version: row.version,
            author: row.author,
            error: None,
        }
    }
}

// ---------------------------------------------------------------------------
// Handler impls — actor-to-actor
// ---------------------------------------------------------------------------

#[async_trait]
impl Handler<GetFeed> for RegistryActor {
    type Result = Result<Arc<CachedFeed<LuaFeed>>, ResolveError>;

    async fn handle(&mut self, msg: GetFeed, _: &Context<Self>) -> Self::Result {
        let db = self.db.as_ref().ok_or(ResolveError::DirNotSet)?;

        if let Some(feed) = self.feeds.get(&msg.feed_id) {
            return Ok(Arc::new(CachedFeed::new(
                Arc::clone(feed),
                db.clone(),
            )));
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

#[cfg(test)]
mod tests {
    use std::error::Error;

    use langhuan::db::Db;
    use langhuan::script::runtime::ScriptEngine;

    use super::*;

    type TestResult = Result<(), Box<dyn Error>>;

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

    #[tokio::test]
    async fn initialize_loads_feeds_from_database() -> TestResult {
        let db = Db::open_in_memory().await?;
        // Seed one feed directly through the repo layer.
        let meta = langhuan::feed::FeedMeta {
            id: "f1".to_owned(),
            name: "Feed One".to_owned(),
            version: "1.0.0".to_owned(),
            author: None,
            description: None,
            base_url: "https://example.com".to_owned(),
            access_domains: Default::default(),
            schema_version: 1,
        };
        db.write(move |conn| {
            conn.upsert_feed(&meta, None, "hash", 1)?;
            conn.upsert_script("f1", "1.0.0", "hash", "-- not lua", 1)
        })
        .await?;

        let mut actor = RegistryActor::new(ScriptEngine::new());
        let result = actor.initialize_app_data_directory(db).await?;
        // The seeded script fails to compile, but registration survives.
        assert_eq!(result.feed_count, 0);
        assert!(result.warning_message.is_some());
        assert!(actor.load_errors.contains_key("f1"));
        Ok(())
    }

    #[tokio::test]
    async fn pending_installs_are_capped_and_lru() {
        let mut actor = RegistryActor::new(ScriptEngine::new());
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

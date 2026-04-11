//! [`RegistryActor`] — manages the script registry and feed installation.

use std::collections::HashMap;
use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use async_trait::async_trait;
use std::collections::HashSet;

use langhuan::cache::{CacheStore, CachedFeed};
use langhuan::script::lua::LuaFeed;
use langhuan::script::registry::ScriptRegistry;
use langhuan::script::runtime::ScriptEngine;
use messages::prelude::{Actor, Address, Context, Handler};

use crate::api::types::{BridgeError, FeedMetaItem, FeedPreviewInfo};
use crate::localize_error;

use super::app_data_actor::InitializeAppDataDirectory;

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
// Actor-to-actor messages (unchanged)
// ---------------------------------------------------------------------------

pub struct GetFeed {
    pub feed_id: String,
}

pub struct GetFeedIds;

// ---------------------------------------------------------------------------
// FRB-facing messages (replace old DartSignal types)
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

/// Message: clean up stale cache entries.
pub struct CleanupStaleCache {
    pub protected: HashSet<(String, String)>,
    pub max_age: std::time::Duration,
}

// ---------------------------------------------------------------------------
// RegistryActor
// ---------------------------------------------------------------------------

pub struct RegistryActor {
    engine: ScriptEngine,
    registry: Option<ScriptRegistry>,
    cache_store: Option<CacheStore>,
    load_errors: HashMap<String, String>,
    pending_installs: HashMap<String, String>,
}

impl Actor for RegistryActor {}

impl RegistryActor {
    pub fn new(self_addr: Address<Self>, engine: ScriptEngine) -> Self {
        let _ = self_addr; // kept for API compat with create_actors
        Self {
            engine,
            registry: None,
            cache_store: None,
            load_errors: HashMap::new(),
            pending_installs: HashMap::new(),
        }
    }

    // -----------------------------------------------------------------------
    // Business logic
    // -----------------------------------------------------------------------

    async fn initialize_app_data_directory(
        &mut self,
        path: &str,
    ) -> Result<RegistryInitializationResult, String> {
        tracing::info!(path = %path, "initializing registry actor storage");
        if self.registry.is_some() {
            return Err(t!("error.registry_reload_not_supported").to_string());
        }
        let base_dir = Path::new(path);
        let scripts_dir = scripts_dir(base_dir);
        let cache_dir = cache_dir(base_dir);

        if let Err(e) = tokio::fs::create_dir_all(&scripts_dir).await {
            return Err(e.to_string());
        }
        if let Err(e) = tokio::fs::create_dir_all(&cache_dir).await {
            return Err(e.to_string());
        }

        if let Err(e) = ScriptRegistry::ensure_registry(&scripts_dir).await {
            return Err(localize_error(&e));
        }

        let entries = match ScriptRegistry::load_entries(&scripts_dir).await {
            Ok(r) => r,
            Err(e) => return Err(localize_error(&e)),
        };

        let mut feeds = HashMap::new();
        let mut load_errors: HashMap<String, String> = HashMap::new();

        for entry in entries.values() {
            match ScriptRegistry::load_feed(&scripts_dir, entry, &self.engine).await {
                Err(e) => {
                    load_errors.insert(entry.id.clone(), localize_error(&e));
                }
                Ok(feed) => {
                    feeds.insert(entry.id.clone(), Arc::new(feed));
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

        self.registry = Some(
            ScriptRegistry::new(&scripts_dir, entries, feeds).map_err(|e| localize_error(&e))?,
        );
        self.cache_store = Some(CacheStore::new(cache_dir));
        self.load_errors = load_errors;
        tracing::info!(
            feed_count = feed_count,
            "registry actor storage initialized"
        );

        Ok(RegistryInitializationResult {
            feed_count,
            warning_message: error_summary,
        })
    }

    fn do_list_feeds(&self) -> Vec<FeedMetaItem> {
        match &self.registry {
            None => vec![],
            Some(registry) => registry
                .list_entries()
                .map(|entry| FeedMetaItem {
                    id: entry.id.clone(),
                    name: entry.name.clone(),
                    version: entry.version.clone(),
                    author: entry.author.clone(),
                    error: self.load_errors.get(&entry.id).cloned(),
                })
                .collect(),
        }
    }

    fn require_registry(&mut self) -> Result<&mut ScriptRegistry, BridgeError> {
        self.registry
            .as_mut()
            .ok_or_else(|| BridgeError::from(t!("error.app_data_dir_not_set").to_string()))
    }

    async fn do_preview_from_url(&mut self, url: String) -> Result<FeedPreviewInfo, BridgeError> {
        tracing::debug!(url = %url, "preview feed from url");
        let content = langhuan::script::source::download_script(&url)
            .await
            ?;
        self.do_preview(content)
    }

    async fn do_preview_from_file(&mut self, path: String) -> Result<FeedPreviewInfo, BridgeError> {
        tracing::debug!(path = %path, "preview feed from file");
        let content = tokio::fs::read_to_string(&path)
            .await
            .map_err(|e| BridgeError::from(t!("error.file_read", error = e.to_string()).to_string()))?;
        self.do_preview(content)
    }

    async fn do_install(&mut self, request_id: String) -> Result<(), BridgeError> {
        tracing::debug!(request_id = %request_id, "install feed");
        let content = self
            .pending_installs
            .remove(&request_id)
            .ok_or_else(|| BridgeError::from(t!("error.no_pending_preview").to_string()))?;

        let registry = self
            .registry
            .as_mut()
            .ok_or_else(|| BridgeError::from(t!("error.app_data_dir_not_set").to_string()))?;

        let entry = registry
            .install_feed(&content, &self.engine)
            .await
            ?;

        self.load_errors.remove(&entry.id);
        Ok(())
    }

    async fn do_remove(&mut self, feed_id: String) -> Result<(), BridgeError> {
        tracing::debug!(feed_id = %feed_id, "remove feed");
        let registry = self.require_registry()?;
        registry
            .remove_feed(&feed_id)
            .await
            ?;
        self.load_errors.remove(&feed_id);
        Ok(())
    }

    /// Parse `content`, cache it as a pending install, and return preview info.
    /// Returns the `request_id` that must be passed to `do_install`.
    fn do_preview(&mut self, content: String) -> Result<FeedPreviewInfo, BridgeError> {
        let (meta, _) = langhuan::script::meta::parse_meta(&content)
            ?;

        let current_version = self
            .registry
            .as_ref()
            .and_then(|reg| reg.entry(&meta.id).map(|entry| entry.version.clone()));

        // Use the feed id as the pending-install key so the caller can pass it
        // back in `InstallFeed`.
        let request_id = meta.id.clone();
        self.pending_installs.insert(request_id, content);

        Ok(FeedPreviewInfo {
            id: meta.id,
            name: meta.name,
            version: meta.version,
            author: meta.author,
            description: meta.description,
            base_url: meta.base_url,
            access_domains: meta.access_domains,
            current_version,
            schema_version: meta.schema_version,
        })
    }
}

// ---------------------------------------------------------------------------
// Handler impls — actor-to-actor
// ---------------------------------------------------------------------------

#[async_trait]
impl Handler<GetFeed> for RegistryActor {
    type Result = Result<Arc<CachedFeed<LuaFeed>>, ResolveError>;

    async fn handle(&mut self, msg: GetFeed, _: &Context<Self>) -> Self::Result {
        let registry = self.registry.as_ref().ok_or(ResolveError::DirNotSet)?;
        let cache_store = self.cache_store.as_ref().ok_or(ResolveError::DirNotSet)?;

        if let Some((_, feed)) = registry.feed(&msg.feed_id) {
            return Ok(Arc::new(CachedFeed::new(
                Arc::clone(feed),
                cache_store.clone(),
            )));
        }

        if registry.has_entry(&msg.feed_id) {
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
        let registry = self.registry.as_ref().ok_or(ResolveError::DirNotSet)?;
        let ids = registry
            .list_entries()
            .map(|entry| entry.id.clone())
            .collect::<Vec<_>>();
        Ok(ids)
    }
}

// ---------------------------------------------------------------------------
// Handler impls — FRB-facing
// ---------------------------------------------------------------------------

#[async_trait]
impl Handler<InitializeAppDataDirectory> for RegistryActor {
    type Result = Result<RegistryInitializationResult, String>;

    async fn handle(&mut self, msg: InitializeAppDataDirectory, _: &Context<Self>) -> Self::Result {
        self.initialize_app_data_directory(&msg.path).await
    }
}

#[async_trait]
impl Handler<ListFeeds> for RegistryActor {
    type Result = Vec<FeedMetaItem>;

    async fn handle(&mut self, _: ListFeeds, _: &Context<Self>) -> Self::Result {
        self.do_list_feeds()
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
impl Handler<CleanupStaleCache> for RegistryActor {
    type Result = Result<u64, BridgeError>;

    async fn handle(&mut self, msg: CleanupStaleCache, _: &Context<Self>) -> Self::Result {
        let store = self
            .cache_store
            .as_ref()
            .ok_or_else(|| BridgeError::from(t!("error.app_data_dir_not_set").to_string()))?;

        store
            .cleanup_stale_books(&msg.protected, msg.max_age)
            .await
            .map_err(BridgeError::from)
    }
}

fn cache_dir(base_dir: &Path) -> PathBuf {
    base_dir.join("cache")
}

fn scripts_dir(base_dir: &Path) -> std::path::PathBuf {
    base_dir.join("scripts")
}

#[cfg(test)]
mod tests {
    use std::error::Error;

    use langhuan::script::runtime::ScriptEngine;
    use messages::prelude::Context;

    use super::*;

    type TestResult = Result<(), Box<dyn Error>>;

    #[tokio::test]
    async fn initialize_app_data_directory_creates_registry_under_scripts_subdir() -> TestResult {
        let dir = tempfile::tempdir()?;
        let registry_context = Context::new();
        let registry_address = registry_context.address();
        let mut actor = RegistryActor::new(registry_address, ScriptEngine::new());

        let result = actor
            .initialize_app_data_directory(&dir.path().to_string_lossy())
            .await;

        let result = result.map_err(std::io::Error::other)?;
        assert_eq!(result.feed_count, 0);
        assert!(result.warning_message.is_none());
        assert!(dir.path().join("scripts").is_dir());
        assert!(dir.path().join("scripts/registry.json").is_file());
        assert!(!dir.path().join("registry.json").exists());
        Ok(())
    }
}

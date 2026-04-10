//! [`RegistryActor`] — manages the script registry and feed installation.
//!
//! # Responsibilities
//! - Accept internal app-data initialization requests to load the script
//!   registry from the scripts subdirectory and pre-compile every feed listed
//!   in it.
//! - Accept `ListFeedsRequest` from Dart to enumerate registered feeds.
//! - Accept `PreviewFeedFromUrl` / `PreviewFeedFromFile` from Dart to preview
//!   a feed script before installation.
//! - Accept `InstallFeedRequest` / `RemoveFeedRequest` from Dart to manage
//!   installed feeds.
//! - Respond to `GetFeed` handler requests from other actors (e.g.
//!   [`StreamActor`](super::stream_actor::StreamActor)) to look up a
//!   pre-compiled [`LuaFeed`] by feed ID.

use std::collections::HashMap;
use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use async_trait::async_trait;
use langhuan::cache::{CacheStore, CachedFeed};
use langhuan::script::lua::LuaFeed;
use langhuan::script::registry::ScriptRegistry;
use langhuan::script::runtime::ScriptEngine;
use messages::prelude::{Actor, Address, Context, Handler, Notifiable};
use rinf::{DartSignal, RustSignal};
use tokio::task::JoinSet;

use crate::localize_error;
use crate::signals::{
    FeedInstallResult, FeedListResult, FeedMetaItem, FeedPreviewOutcome, FeedPreviewResult,
    FeedRemoveResult, InstallFeedRequest, ListFeedsRequest, PreviewFeedFromFile,
    PreviewFeedFromUrl, RemoveFeedRequest,
};

use super::app_data_actor::InitializeAppDataDirectory;

pub struct RegistryInitializationResult {
    pub feed_count: u32,
    pub warning_message: Option<String>,
}

// ---------------------------------------------------------------------------
// ResolveError
// ---------------------------------------------------------------------------

/// Error returned by [`Handler<GetFeed>`] when a feed cannot be resolved.
#[derive(Debug, Clone)]
pub enum ResolveError {
    /// App data directory has not been set yet.
    DirNotSet,
    /// Feed exists in registry but failed to compile.
    Unavailable { id: String },
    /// Feed ID not found in registry.
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
// GetFeed message
// ---------------------------------------------------------------------------

/// Request message sent by [`StreamActor`](super::stream_actor::StreamActor)
/// to look up a pre-compiled feed.
pub struct GetFeed {
    pub feed_id: String,
}

/// Request all feed IDs currently known to registry entries.
pub struct GetFeedIds;

// ---------------------------------------------------------------------------
// RegistryActor
// ---------------------------------------------------------------------------

/// Manages the script registry, feed compilation, preview, install, and
/// removal.
pub struct RegistryActor {
    engine: ScriptEngine,
    /// The currently loaded script registry.  `None` until
    /// `do_set_directory` succeeds for the first time.
    registry: Option<ScriptRegistry>,
    /// Shared cache store used by [`CachedFeed`] wrappers.
    cache_store: Option<Arc<CacheStore>>,
    /// Per-feed compile errors keyed by `feed_id`.
    load_errors: HashMap<String, String>,
    /// Pending feed installs awaiting user confirmation, keyed by `request_id`.
    pending_installs: HashMap<String, String>,
    /// Owned tasks that are canceled when the actor is dropped.
    _owned_tasks: JoinSet<()>,
}

impl Actor for RegistryActor {}

impl RegistryActor {
    /// Creates the actor and spawns listener tasks for all registry-related
    /// Dart signal types.
    pub fn new(self_addr: Address<Self>, engine: ScriptEngine) -> Self {
        let mut _owned_tasks = JoinSet::new();
        _owned_tasks.spawn(Self::listen_to_list_feeds(self_addr.clone()));
        _owned_tasks.spawn(Self::listen_to_preview_from_url(self_addr.clone()));
        _owned_tasks.spawn(Self::listen_to_preview_from_file(self_addr.clone()));
        _owned_tasks.spawn(Self::listen_to_install(self_addr.clone()));
        _owned_tasks.spawn(Self::listen_to_remove(self_addr.clone()));
        Self {
            engine,
            registry: None,
            cache_store: None,
            load_errors: HashMap::new(),
            pending_installs: HashMap::new(),
            _owned_tasks,
        }
    }

    // -----------------------------------------------------------------------
    // Business logic
    // -----------------------------------------------------------------------

    /// Load (or reload) the script registry from the scripts subdirectory and
    /// eagerly compile every feed listed in it.
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

        // Ensure registry.json exists (creates an empty one on first run).
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
        self.cache_store = Some(Arc::new(CacheStore::new(cache_dir)));
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

    /// Enumerate all feeds in the current registry.
    fn do_list_feeds(&self, req: ListFeedsRequest) -> FeedListResult {
        tracing::debug!(request_id = %req.request_id, "received list feeds request");
        let items = match &self.registry {
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
        };
        FeedListResult::new(req.request_id, items)
    }

    fn require_registry(&mut self) -> Result<&mut ScriptRegistry, String> {
        self.registry
            .as_mut()
            .ok_or_else(|| t!("error.app_data_dir_not_set").to_string())
    }

    /// Preview a feed script fetched from a remote URL.
    async fn do_preview_from_url(&mut self, req: PreviewFeedFromUrl) -> FeedPreviewResult {
        tracing::debug!(request_id = %req.request_id, url = %req.url, "received feed preview from url request");
        let content = match langhuan::script::source::download_script(&req.url).await {
            Ok(c) => c,
            Err(e) => {
                return FeedPreviewResult::error(req.request_id, localize_error(&e));
            }
        };
        self.do_preview(req.request_id, content)
    }

    /// Preview a feed script read from a local file path.
    async fn do_preview_from_file(&mut self, req: PreviewFeedFromFile) -> FeedPreviewResult {
        tracing::debug!(request_id = %req.request_id, path = %req.path, "received feed preview from file request");
        let content = match tokio::fs::read_to_string(&req.path).await {
            Ok(c) => c,
            Err(e) => {
                let message = t!("error.file_read", error = e.to_string()).to_string();
                return FeedPreviewResult::error(req.request_id, message);
            }
        };
        self.do_preview(req.request_id, content)
    }

    /// Confirm installation of a previously previewed feed.
    async fn do_install(&mut self, req: InstallFeedRequest) -> FeedInstallResult {
        tracing::debug!(request_id = %req.request_id, "received feed install request");
        let request_id = req.request_id;
        let content = match self.pending_installs.remove(&request_id) {
            Some(c) => c,
            None => {
                return FeedInstallResult::error(
                    request_id,
                    t!("error.no_pending_preview").to_string(),
                );
            }
        };

        let registry = match self.registry.as_mut() {
            Some(registry) => registry,
            None => {
                return FeedInstallResult::error(
                    request_id,
                    t!("error.app_data_dir_not_set").to_string(),
                );
            }
        };

        let entry = match registry.install_feed(&content, &self.engine).await {
            Ok(e) => e,
            Err(e) => {
                return FeedInstallResult::error(request_id, localize_error(&e));
            }
        };

        self.load_errors.remove(&entry.id);

        FeedInstallResult::success(request_id)
    }

    /// Remove an installed feed and update both in-memory state and disk.
    async fn do_remove(&mut self, req: RemoveFeedRequest) -> FeedRemoveResult {
        tracing::debug!(request_id = %req.request_id, feed_id = %req.feed_id, "received feed remove request");
        let request_id = req.request_id;
        let registry = match self.require_registry() {
            Ok(registry) => registry,
            Err(message) => return FeedRemoveResult::error(request_id, message),
        };

        match registry.remove_feed(&req.feed_id).await {
            Ok(()) => {
                self.load_errors.remove(&req.feed_id);
                FeedRemoveResult::success(request_id)
            }
            Err(e) => FeedRemoveResult::error(request_id, localize_error(&e)),
        }
    }

    /// Parse `content`, cache it as a pending install, and build a
    /// [`FeedPreviewResult`].
    fn do_preview(&mut self, request_id: String, content: String) -> FeedPreviewResult {
        let (meta, _) = match langhuan::script::meta::parse_meta(&content) {
            Ok(m) => m,
            Err(e) => {
                return FeedPreviewResult::error(request_id, localize_error(&e));
            }
        };

        let current_version = self
            .registry
            .as_ref()
            .and_then(|reg| reg.entry(&meta.id).map(|entry| entry.version.clone()));
        self.pending_installs.insert(request_id.clone(), content);

        FeedPreviewResult::success(
            request_id,
            FeedPreviewOutcome::Success {
                id: meta.id.clone(),
                name: meta.name.clone(),
                version: meta.version.clone(),
                author: meta.author.clone(),
                description: meta.description.clone(),
                base_url: meta.base_url.clone(),
                access_domains: meta.access_domains.clone(),
                current_version,
                schema_version: meta.schema_version,
            },
        )
    }
}

// ---------------------------------------------------------------------------
// Handler impl — GetFeed (request-response from StreamActor)
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
                Arc::clone(cache_store),
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

fn cache_dir(base_dir: &Path) -> PathBuf {
    base_dir.join("cache")
}

// ---------------------------------------------------------------------------
// Notifiable impls
// ---------------------------------------------------------------------------

#[async_trait]
impl Handler<InitializeAppDataDirectory> for RegistryActor {
    type Result = Result<RegistryInitializationResult, String>;

    async fn handle(&mut self, msg: InitializeAppDataDirectory, _: &Context<Self>) -> Self::Result {
        self.initialize_app_data_directory(&msg.path).await
    }
}

#[async_trait]
impl Notifiable<ListFeedsRequest> for RegistryActor {
    async fn notify(&mut self, msg: ListFeedsRequest, _: &Context<Self>) {
        self.do_list_feeds(msg).send_signal_to_dart();
    }
}

#[async_trait]
impl Notifiable<PreviewFeedFromUrl> for RegistryActor {
    async fn notify(&mut self, msg: PreviewFeedFromUrl, _: &Context<Self>) {
        self.do_preview_from_url(msg).await.send_signal_to_dart();
    }
}

#[async_trait]
impl Notifiable<PreviewFeedFromFile> for RegistryActor {
    async fn notify(&mut self, msg: PreviewFeedFromFile, _: &Context<Self>) {
        self.do_preview_from_file(msg).await.send_signal_to_dart();
    }
}

#[async_trait]
impl Notifiable<InstallFeedRequest> for RegistryActor {
    async fn notify(&mut self, msg: InstallFeedRequest, _: &Context<Self>) {
        self.do_install(msg).await.send_signal_to_dart();
    }
}

#[async_trait]
impl Notifiable<RemoveFeedRequest> for RegistryActor {
    async fn notify(&mut self, msg: RemoveFeedRequest, _: &Context<Self>) {
        self.do_remove(msg).await.send_signal_to_dart();
    }
}

// ---------------------------------------------------------------------------
// Dart signal listeners
// ---------------------------------------------------------------------------

impl RegistryActor {
    async fn listen_to_list_feeds(mut self_addr: Address<Self>) {
        let receiver = ListFeedsRequest::get_dart_signal_receiver();
        while let Some(signal_pack) = receiver.recv().await {
            let _ = self_addr.notify(signal_pack.message).await;
        }
    }

    async fn listen_to_preview_from_url(mut self_addr: Address<Self>) {
        let receiver = PreviewFeedFromUrl::get_dart_signal_receiver();
        while let Some(signal_pack) = receiver.recv().await {
            let _ = self_addr.notify(signal_pack.message).await;
        }
    }

    async fn listen_to_preview_from_file(mut self_addr: Address<Self>) {
        let receiver = PreviewFeedFromFile::get_dart_signal_receiver();
        while let Some(signal_pack) = receiver.recv().await {
            let _ = self_addr.notify(signal_pack.message).await;
        }
    }

    async fn listen_to_install(mut self_addr: Address<Self>) {
        let receiver = InstallFeedRequest::get_dart_signal_receiver();
        while let Some(signal_pack) = receiver.recv().await {
            let _ = self_addr.notify(signal_pack.message).await;
        }
    }

    async fn listen_to_remove(mut self_addr: Address<Self>) {
        let receiver = RemoveFeedRequest::get_dart_signal_receiver();
        while let Some(signal_pack) = receiver.recv().await {
            let _ = self_addr.notify(signal_pack.message).await;
        }
    }
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

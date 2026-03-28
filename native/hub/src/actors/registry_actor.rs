//! [`RegistryActor`] — manages the script registry and feed installation.
//!
//! # Responsibilities
//! - Accept `SetScriptDirectory` from Dart to (re-)load the script registry and
//!   pre-compile every feed listed in it.
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
use std::path::Path;
use std::sync::Arc;

use async_trait::async_trait;
use langhuan::script::engine::ScriptEngine;
use langhuan::script::lua_feed::LuaFeed;
use langhuan::script::registry::ScriptRegistry;
use messages::prelude::{Actor, Address, Context, Handler, Notifiable};
use rinf::{DartSignal, RustSignal};
use tokio::task::JoinSet;

use crate::localize_error;
use crate::signals::{
    FeedInstallResult, FeedListResult, FeedMetaItem, FeedPreviewResult, InstallFeedRequest,
    ListFeedsRequest, PreviewFeedFromFile, PreviewFeedFromUrl, RemoveFeedRequest, FeedRemoveResult,
    ScriptDirectorySet, SetScriptDirectory,
};

// ---------------------------------------------------------------------------
// ResolveError
// ---------------------------------------------------------------------------

/// Error returned by [`Handler<GetFeed>`] when a feed cannot be resolved.
#[derive(Debug, Clone)]
pub enum ResolveError {
    /// Script directory has not been set yet.
    DirNotSet,
    /// Feed exists in registry but failed to compile.
    Unavailable { id: String },
    /// Feed ID not found in registry.
    NotFound { id: String },
}

impl fmt::Display for ResolveError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ResolveError::DirNotSet => write!(f, "{}", t!("error.script_dir_not_set")),
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
        _owned_tasks.spawn(Self::listen_to_set_directory(self_addr.clone()));
        _owned_tasks.spawn(Self::listen_to_list_feeds(self_addr.clone()));
        _owned_tasks.spawn(Self::listen_to_preview_from_url(self_addr.clone()));
        _owned_tasks.spawn(Self::listen_to_preview_from_file(self_addr.clone()));
        _owned_tasks.spawn(Self::listen_to_install(self_addr.clone()));
        _owned_tasks.spawn(Self::listen_to_remove(self_addr));
        Self {
            engine,
            registry: None,
            load_errors: HashMap::new(),
            pending_installs: HashMap::new(),
            _owned_tasks,
        }
    }

    // -----------------------------------------------------------------------
    // Business logic
    // -----------------------------------------------------------------------

    /// Load (or reload) the script registry from `path` and eagerly compile
    /// every feed listed in it.
    async fn do_set_directory(&mut self, req: SetScriptDirectory) -> ScriptDirectorySet {
        if self.registry.is_some() {
            return ScriptDirectorySet {
                success: false,
                feed_count: 0,
                error: Some(t!("error.registry_reload_not_supported").to_string()),
            };
        }
        // Create the directory (and any parents) if it does not exist yet.
        if let Err(e) = tokio::fs::create_dir_all(&req.path).await {
            return ScriptDirectorySet {
                success: false,
                feed_count: 0,
                error: Some(e.to_string()),
            };
        }

        // Ensure registry.toml exists (creates an empty one on first run).
        if let Err(e) = ScriptRegistry::ensure_registry(Path::new(&req.path)).await {
            return ScriptDirectorySet {
                success: false,
                feed_count: 0,
                error: Some(localize_error(&e)),
            };
        }

        let entries = match ScriptRegistry::load_entries(Path::new(&req.path)).await {
            Ok(r) => r,
            Err(e) => {
                return ScriptDirectorySet {
                    success: false,
                    feed_count: 0,
                    error: Some(localize_error(&e)),
                };
            }
        };

        let mut feeds = HashMap::new();
        let mut load_errors: HashMap<String, String> = HashMap::new();

        for entry in entries.values() {
            match ScriptRegistry::load_feed(Path::new(&req.path), entry, &self.engine).await {
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
            ScriptRegistry::new(Path::new(&req.path), entries, feeds).unwrap_or_else(|e| {
                panic!("Failed to initialize script registry: {}", e);
            }),
        );
        self.load_errors = load_errors;

        ScriptDirectorySet {
            success: error_summary.is_none(),
            feed_count,
            error: error_summary,
        }
    }

    /// Enumerate all feeds in the current registry.
    fn do_list_feeds(&self, req: ListFeedsRequest) -> FeedListResult {
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
        FeedListResult {
            request_id: req.request_id,
            items,
        }
    }

    /// Preview a feed script fetched from a remote URL.
    async fn do_preview_from_url(&mut self, req: PreviewFeedFromUrl) -> FeedPreviewResult {
        let content = match langhuan::script::downloader::download_script(&req.url).await {
            Ok(c) => c,
            Err(e) => {
                return FeedPreviewResult {
                    request_id: req.request_id,
                    id: String::new(),
                    name: String::new(),
                    version: String::new(),
                    author: None,
                    description: None,
                    base_url: String::new(),
                    allowed_domains: vec![],
                    is_upgrade: false,
                    current_version: None,
                    error: Some(localize_error(&e)),
                };
            }
        };
        self.do_preview(req.request_id, content)
    }

    /// Preview a feed script read from a local file path.
    async fn do_preview_from_file(&mut self, req: PreviewFeedFromFile) -> FeedPreviewResult {
        let content = match tokio::fs::read_to_string(&req.path).await {
            Ok(c) => c,
            Err(e) => {
                let msg = t!("error.file_read", error = e.to_string()).to_string();
                return FeedPreviewResult {
                    request_id: req.request_id,
                    id: String::new(),
                    name: String::new(),
                    version: String::new(),
                    author: None,
                    description: None,
                    base_url: String::new(),
                    allowed_domains: vec![],
                    is_upgrade: false,
                    current_version: None,
                    error: Some(msg),
                };
            }
        };
        self.do_preview(req.request_id, content)
    }

    /// Confirm installation of a previously previewed feed.
    async fn do_install(&mut self, req: InstallFeedRequest) -> FeedInstallResult {
        let content = match self.pending_installs.remove(&req.request_id) {
            Some(c) => c,
            None => {
                return FeedInstallResult {
                    request_id: req.request_id,
                    success: false,
                    error: Some(t!("error.no_pending_preview").to_string()),
                };
            }
        };

        let registry = match self.registry.as_mut() {
            Some(registry) => registry,
            None => {
                return FeedInstallResult {
                    request_id: req.request_id,
                    success: false,
                    error: Some(t!("error.script_dir_not_set").to_string()),
                };
            }
        };

        let entry = match registry.install_feed(&content, &self.engine).await {
            Ok(e) => e,
            Err(e) => {
                return FeedInstallResult {
                    request_id: req.request_id,
                    success: false,
                    error: Some(localize_error(&e)),
                };
            }
        };

        self.load_errors.remove(&entry.id);

        FeedInstallResult {
            request_id: req.request_id,
            success: true,
            error: None,
        }
    }

    /// Remove an installed feed and update both in-memory state and disk.
    async fn do_remove(&mut self, req: RemoveFeedRequest) -> FeedRemoveResult {
        let registry = match self.registry.as_mut() {
            Some(registry) => registry,
            None => {
                return FeedRemoveResult {
                    request_id: req.request_id,
                    success: false,
                    error: Some(t!("error.script_dir_not_set").to_string()),
                };
            }
        };

        match registry.remove_feed(&req.feed_id).await {
            Ok(()) => {
                self.load_errors.remove(&req.feed_id);
                FeedRemoveResult {
                    request_id: req.request_id,
                    success: true,
                    error: None,
                }
            }
            Err(e) => FeedRemoveResult {
                request_id: req.request_id,
                success: false,
                error: Some(localize_error(&e)),
            },
        }
    }

    /// Parse `content`, cache it as a pending install, and build a
    /// [`FeedPreviewResult`].
    fn do_preview(&mut self, request_id: String, content: String) -> FeedPreviewResult {
        let (meta, _) = match langhuan::script::meta::parse_meta(&content) {
            Ok(m) => m,
            Err(e) => {
                return FeedPreviewResult {
                    request_id,
                    id: String::new(),
                    name: String::new(),
                    version: String::new(),
                    author: None,
                    description: None,
                    base_url: String::new(),
                    allowed_domains: vec![],
                    is_upgrade: false,
                    current_version: None,
                    error: Some(localize_error(&e)),
                };
            }
        };

        let (is_upgrade, current_version) = match &self.registry {
            Some(reg) => (
                reg.has_entry(&meta.id),
                reg.entry(&meta.id).map(|entry| entry.version.clone()),
            ),
            None => (false, None),
        };

        self.pending_installs.insert(request_id.clone(), content);

        FeedPreviewResult {
            request_id,
            id: meta.id.clone(),
            name: meta.name.clone(),
            version: meta.version.clone(),
            author: meta.author.clone(),
            description: meta.description.clone(),
            base_url: meta.base_url.clone(),
            allowed_domains: meta.allowed_domains.clone(),
            is_upgrade,
            current_version,
            error: None,
        }
    }
}

// ---------------------------------------------------------------------------
// Handler impl — GetFeed (request-response from StreamActor)
// ---------------------------------------------------------------------------

#[async_trait]
impl Handler<GetFeed> for RegistryActor {
    type Result = Result<Arc<LuaFeed>, ResolveError>;

    async fn handle(&mut self, msg: GetFeed, _: &Context<Self>) -> Self::Result {
        let registry = self
            .registry
            .as_ref()
            .ok_or(ResolveError::DirNotSet)?;

        if let Some((_, feed)) = registry.feed(&msg.feed_id) {
            return Ok(Arc::clone(feed));
        }

        if registry.has_entry(&msg.feed_id) {
            Err(ResolveError::Unavailable {
                id: msg.feed_id,
            })
        } else {
            Err(ResolveError::NotFound {
                id: msg.feed_id,
            })
        }
    }
}

// ---------------------------------------------------------------------------
// Notifiable impls
// ---------------------------------------------------------------------------

#[async_trait]
impl Notifiable<SetScriptDirectory> for RegistryActor {
    async fn notify(&mut self, msg: SetScriptDirectory, _: &Context<Self>) {
        self.do_set_directory(msg).await.send_signal_to_dart();
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
    async fn listen_to_set_directory(mut self_addr: Address<Self>) {
        let receiver = SetScriptDirectory::get_dart_signal_receiver();
        while let Some(signal_pack) = receiver.recv().await {
            let _ = self_addr.notify(signal_pack.message).await;
        }
    }

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

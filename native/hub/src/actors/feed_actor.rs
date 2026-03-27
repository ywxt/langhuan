//! [`FeedActor`] — manages feed stream requests from Dart.
//!
//! # Responsibilities
//! - Accept `SearchRequest`, `ChaptersRequest`, `ChapterContentRequest` from Dart.
//! - Launch each request as an independent async task identified by `request_id`.
//! - Support concurrent in-flight requests (multiple parallel streams).
//! - Accept `FeedCancelRequest` from Dart and abort the matching task.
//! - Emit per-item signals and a terminal `FeedStreamEnd` for every request.
//! - Accept `SetScriptDirectory` from Dart to (re-)load the script registry and
//!   pre-compile every feed listed in it.
//! - Accept `ListFeedsRequest` from Dart to enumerate registered feeds.
//!
//! # Script loading
//! On `SetScriptDirectory` the actor reads `registry.toml`, then eagerly
//! compiles every listed Lua script into a [`LuaFeed`] stored in `feeds`.
//! Subsequent stream requests look up the pre-compiled feed by `feed_id` — no
//! disk I/O or Lua compilation happens at request time.
//!
//! # Retry
//! Retry with exponential back-off is handled inside `langhuan::LuaFeed`.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use langhuan::feed::Feed;
use langhuan::script::engine::ScriptEngine;
use langhuan::script::lua_feed::LuaFeed;
use langhuan::script::registry::ScriptRegistry;
use rinf::RustSignal;
use tokio::task::JoinHandle;
use tokio_stream::StreamExt;
use tokio_util::sync::CancellationToken;

use crate::localize_error;
use crate::signals::{
    ChapterContentRequest, ChapterInfoItem, ChapterParagraphItem, ChaptersRequest,
    FeedCancelRequest, FeedInstallResult, FeedListResult, FeedMetaItem, FeedPreviewResult,
    FeedStreamEnd, FeedStreamStatus, InstallFeedRequest, ListFeedsRequest, ParagraphContent,
    PreviewFeedFromFile, PreviewFeedFromUrl, ScriptDirectorySet, SearchRequest, SearchResultItem,
    SetScriptDirectory,
};

// ---------------------------------------------------------------------------
// FeedActor
// ---------------------------------------------------------------------------

/// Manages the lifecycle of all in-flight feed streams and the script registry.
pub struct FeedActor {
    engine: Arc<ScriptEngine>,
    /// The currently loaded script registry.  `None` until
    /// [`handle_set_directory`] succeeds for the first time.
    registry: Option<Arc<ScriptRegistry>>,
    /// Pre-compiled feeds keyed by `feed_id`.
    /// Populated (and replaced) each time [`handle_set_directory`] succeeds.
    feeds: HashMap<String, Arc<LuaFeed>>,
    /// Live tasks keyed by `request_id`.  Each entry holds a cancellation
    /// token (to request cooperative shutdown) and a join handle (for cleanup).
    tasks: HashMap<String, (CancellationToken, JoinHandle<()>)>,
    /// Base directory used by the current registry.  Set when
    /// [`handle_set_directory`] succeeds; needed by [`handle_install`].
    scripts_dir: Option<PathBuf>,
    /// Pending feed installs awaiting user confirmation, keyed by `request_id`.
    /// Maps to the raw Lua script content returned by the preview step.
    pending_installs: HashMap<String, String>,
}

impl FeedActor {
    pub fn new(engine: ScriptEngine) -> Self {
        Self {
            engine: Arc::new(engine),
            registry: None,
            feeds: HashMap::new(),
            tasks: HashMap::new(),
            scripts_dir: None,
            pending_installs: HashMap::new(),
        }
    }

    // -----------------------------------------------------------------------
    // Registry management
    // -----------------------------------------------------------------------

    /// Load (or reload) the script registry from `path` and eagerly compile
    /// every feed listed in it.
    ///
    /// On success the old registry **and** feed map are replaced and a
    /// confirmation signal is sent to Dart.  Feeds that fail to compile are
    /// skipped; their errors are reported in the `error` field of the signal.
    /// On registry-load failure the **old state is kept** (degraded-mode
    /// protection) and an error signal is sent.
    pub async fn handle_set_directory(&mut self, req: SetScriptDirectory) {
        // Always record the directory so that install works even when the
        // registry.toml does not exist yet (first-run / empty directory).
        self.scripts_dir = Some(PathBuf::from(&req.path));

        let registry = match ScriptRegistry::load(Path::new(&req.path)).await {
            Ok(r) => r,
            Err(e) => {
                ScriptDirectorySet {
                    success: false,
                    feed_count: 0,
                    error: Some(localize_error(&e)),
                }
                .send_signal_to_dart();
                return;
            }
        };

        // Eagerly compile every feed listed in the registry.
        let mut feeds = HashMap::new();
        let mut load_errors: Vec<String> = Vec::new();

        for entry in registry.list_entries() {
            match registry.get_script(&entry.id).await {
                Err(e) => load_errors.push(format!("{}: {}", entry.id, e)),
                Ok(script) => match self.engine.load_feed(&script).await {
                    Ok(feed) => {
                        feeds.insert(entry.id.clone(), Arc::new(feed));
                    }
                    Err(e) => load_errors.push(format!("{}: {}", entry.id, e)),
                },
            }
        }

        let feed_count = feeds.len() as u32;
        self.registry = Some(Arc::new(registry));
        self.feeds = feeds;

        ScriptDirectorySet {
            success: true,
            feed_count,
            error: if load_errors.is_empty() {
                None
            } else {
                Some(load_errors.join("; "))
            },
        }
        .send_signal_to_dart();
    }

    /// Enumerate all feeds in the current registry and send the list to Dart.
    pub fn handle_list_feeds(&self, req: ListFeedsRequest) {
        let items = match &self.registry {
            None => vec![],
            Some(registry) => registry
                .list_entries()
                .map(|e| FeedMetaItem {
                    id: e.id.clone(),
                    name: e.name.clone(),
                    version: e.version.clone(),
                    author: e.author.clone(),
                })
                .collect(),
        };
        FeedListResult {
            request_id: req.request_id,
            items,
        }
        .send_signal_to_dart();
    }

    // -----------------------------------------------------------------------
    // Stream request handlers
    // -----------------------------------------------------------------------

    /// Handle an incoming `SearchRequest` from Dart.
    pub fn handle_search(&mut self, req: SearchRequest) {
        let request_id = req.request_id.clone();
        let Some(feed) = self.resolve_feed(&req.feed_id, &request_id) else {
            return;
        };
        let token = CancellationToken::new();
        let child_token = token.clone();

        let handle = tokio::spawn(async move {
            run_search(feed, req, child_token).await;
        });

        self.register_task(request_id, token, handle);
    }

    /// Handle an incoming `ChaptersRequest` from Dart.
    pub fn handle_chapters(&mut self, req: ChaptersRequest) {
        let request_id = req.request_id.clone();
        let Some(feed) = self.resolve_feed(&req.feed_id, &request_id) else {
            return;
        };
        let token = CancellationToken::new();
        let child_token = token.clone();

        let handle = tokio::spawn(async move {
            run_chapters(feed, req, child_token).await;
        });

        self.register_task(request_id, token, handle);
    }

    /// Handle an incoming `ChapterContentRequest` from Dart.
    pub fn handle_chapter_content(&mut self, req: ChapterContentRequest) {
        let request_id = req.request_id.clone();
        let Some(feed) = self.resolve_feed(&req.feed_id, &request_id) else {
            return;
        };
        let token = CancellationToken::new();
        let child_token = token.clone();

        let handle = tokio::spawn(async move {
            run_chapter_content(feed, req, child_token).await;
        });

        self.register_task(request_id, token, handle);
    }

    /// Cancel the task identified by `request_id`, if it is still running.
    pub fn handle_cancel(&mut self, req: FeedCancelRequest) {
        if let Some((token, _handle)) = self.tasks.remove(&req.request_id) {
            // Signal cooperative cancellation — the task will emit a
            // `FeedStreamEnd { status: "cancelled" }` and exit.
            token.cancel();
        }
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    /// Look up a pre-compiled [`LuaFeed`] by `feed_id`.
    ///
    /// Emits a `Failed` [`FeedStreamEnd`] and returns `None` if the directory
    /// has not been set yet or the feed ID is not in the compiled map.
    fn resolve_feed(&self, feed_id: &str, request_id: &str) -> Option<Arc<LuaFeed>> {
        match self.feeds.get(feed_id) {
            Some(feed) => Some(Arc::clone(feed)),
            None => {
                let msg = if self.registry.is_none() {
                    t!("error.script_dir_not_set").to_string()
                } else {
                    t!("error.feed_unavailable", id = feed_id).to_string()
                };
                emit_end(request_id, FeedStreamStatus::Failed, Some(msg));
                None
            }
        }
    }

    fn register_task(
        &mut self,
        request_id: String,
        token: CancellationToken,
        handle: JoinHandle<()>,
    ) {
        // If a previous task with the same id somehow exists, cancel it first.
        if let Some((old_token, _)) = self.tasks.remove(&request_id) {
            old_token.cancel();
        }
        self.tasks.insert(request_id, (token, handle));
    }

    /// Remove tasks that have already finished (keep the map from growing).
    /// Call this periodically or after receiving a request.
    pub fn cleanup_finished(&mut self) {
        self.tasks.retain(|_, (_, handle)| !handle.is_finished());
    }

    // -----------------------------------------------------------------------
    // Feed install handlers
    // -----------------------------------------------------------------------

    /// Preview a feed script fetched from a remote URL.
    pub async fn handle_preview_from_url(&mut self, req: PreviewFeedFromUrl) {
        let content = match langhuan::script::downloader::download_script(&req.url).await {
            Ok(c) => c,
            Err(e) => {
                FeedPreviewResult {
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
                }
                .send_signal_to_dart();
                return;
            }
        };
        self.emit_preview(req.request_id, content);
    }

    /// Preview a feed script read from a local file path.
    pub async fn handle_preview_from_file(&mut self, req: PreviewFeedFromFile) {
        let content = match tokio::fs::read_to_string(&req.path).await {
            Ok(c) => c,
            Err(e) => {
                let msg = t!("error.file_read", error = e.to_string()).to_string();
                FeedPreviewResult {
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
                }
                .send_signal_to_dart();
                return;
            }
        };
        self.emit_preview(req.request_id, content);
    }

    /// Confirm installation of a previously previewed feed.
    pub async fn handle_install(&mut self, req: InstallFeedRequest) {
        let content = match self.pending_installs.remove(&req.request_id) {
            Some(c) => c,
            None => {
                FeedInstallResult {
                    request_id: req.request_id,
                    success: false,
                    error: Some(t!("error.no_pending_preview").to_string()),
                }
                .send_signal_to_dart();
                return;
            }
        };

        let scripts_dir = match &self.scripts_dir {
            Some(d) => d.clone(),
            None => {
                FeedInstallResult {
                    request_id: req.request_id,
                    success: false,
                    error: Some(t!("error.script_dir_not_set").to_string()),
                }
                .send_signal_to_dart();
                return;
            }
        };

        if let Err(e) = langhuan::script::registry::install_feed(&scripts_dir, &content).await {
            FeedInstallResult {
                request_id: req.request_id,
                success: false,
                error: Some(localize_error(&e)),
            }
            .send_signal_to_dart();
            return;
        }

        // Reload the registry so the new feed is immediately available.
        match ScriptRegistry::load(&scripts_dir).await {
            Ok(registry) => {
                let mut feeds = HashMap::new();
                for entry in registry.list_entries() {
                    if let Ok(script) = registry.get_script(&entry.id).await
                        && let Ok(feed) = self.engine.load_feed(&script).await
                    {
                        feeds.insert(entry.id.clone(), Arc::new(feed));
                    }
                }
                self.registry = Some(Arc::new(registry));
                self.feeds = feeds;
            }
            Err(_) => {
                // Install succeeded; registry reload failure is non-fatal —
                // user can call SetScriptDirectory again to force a reload.
            }
        }

        FeedInstallResult {
            request_id: req.request_id,
            success: true,
            error: None,
        }
        .send_signal_to_dart();
    }

    // -----------------------------------------------------------------------
    // Private helpers
    // -----------------------------------------------------------------------

    /// Parse `content`, cache it as a pending install, and send a
    /// [`FeedPreviewResult`] to Dart.
    fn emit_preview(&mut self, request_id: String, content: String) {
        let (meta, _) = match langhuan::script::meta::parse_meta(&content) {
            Ok(m) => m,
            Err(e) => {
                FeedPreviewResult {
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
                }
                .send_signal_to_dart();
                return;
            }
        };

        let (is_upgrade, current_version) = match &self.registry {
            Some(reg) => (
                reg.has_feed(&meta.id),
                reg.get_entry(&meta.id).map(|e| e.version.clone()),
            ),
            None => (false, None),
        };

        // Cache the script content so `handle_install` can write it to disk.
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
        .send_signal_to_dart();
    }
}

// ---------------------------------------------------------------------------
// Task implementations (run inside `tokio::spawn`)
// ---------------------------------------------------------------------------

/// Emit a [`FeedStreamEnd`] signal with the given status and optional error.
fn emit_end(request_id: &str, status: FeedStreamStatus, error: Option<String>) {
    FeedStreamEnd {
        request_id: request_id.to_owned(),
        status,
        error,
        retried_count: 0,
    }
    .send_signal_to_dart();
}

/// Generic stream driver shared by all three `run_*` functions.
///
/// Drives `stream` to completion, calling `emit_item` for every successful
/// item.  Handles cancellation and per-item errors uniformly.
async fn run_stream<T, F>(
    request_id: String,
    mut stream: langhuan::feed::FeedStream<'_, T>,
    token: CancellationToken,
    mut emit_item: F,
) where
    F: FnMut(T),
{
    loop {
        tokio::select! {
            biased;
            _ = token.cancelled() => {
                emit_end(&request_id, FeedStreamStatus::Cancelled, None);
                return;
            }
            item = stream.next() => {
                match item {
                    None => break,
                    Some(Ok(value)) => emit_item(value),
                    Some(Err(e)) => {
                        emit_end(&request_id, FeedStreamStatus::Failed, Some(e.to_string()));
                        return;
                    }
                }
            }
        }
    }
    emit_end(&request_id, FeedStreamStatus::Completed, None);
}

async fn run_search(feed: Arc<LuaFeed>, req: SearchRequest, token: CancellationToken) {
    let stream = feed.search(&req.keyword);
    run_stream(req.request_id.clone(), stream, token, |result| {
        SearchResultItem {
            request_id: req.request_id.clone(),
            id: result.id,
            title: result.title,
            author: result.author,
            cover_url: result.cover_url,
            description: result.description,
        }
        .send_signal_to_dart();
    })
    .await;
}

async fn run_chapters(feed: Arc<LuaFeed>, req: ChaptersRequest, token: CancellationToken) {
    let stream = feed.chapters(&req.book_id);
    run_stream(req.request_id.clone(), stream, token, |chapter| {
        ChapterInfoItem {
            request_id: req.request_id.clone(),
            id: chapter.id,
            title: chapter.title,
            index: chapter.index,
        }
        .send_signal_to_dart();
    })
    .await;
}

async fn run_chapter_content(
    feed: Arc<LuaFeed>,
    req: ChapterContentRequest,
    token: CancellationToken,
) {
    use langhuan::model::Paragraph;

    let stream = feed.paragraphs(&req.chapter_id);
    run_stream(req.request_id.clone(), stream, token, |paragraph| {
        let content = match paragraph {
            Paragraph::Title { text } => ParagraphContent::Title { text },
            Paragraph::Text { content } => ParagraphContent::Text { content },
            Paragraph::Image { url, alt } => ParagraphContent::Image { url, alt },
        };
        ChapterParagraphItem {
            request_id: req.request_id.clone(),
            paragraph: content,
        }
        .send_signal_to_dart();
    })
    .await;
}

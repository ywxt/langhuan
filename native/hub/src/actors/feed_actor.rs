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
use std::path::Path;
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
    FeedRemoveResult, FeedStreamEnd, FeedStreamStatus, InstallFeedRequest, ListFeedsRequest,
    ParagraphContent, PreviewFeedFromFile, PreviewFeedFromUrl, RemoveFeedRequest,
    ScriptDirectorySet, SearchRequest, SearchResultItem, SetScriptDirectory,
};

// ---------------------------------------------------------------------------
// FeedActor
// ---------------------------------------------------------------------------

/// Manages the lifecycle of all in-flight feed streams and the script registry.
pub struct FeedActor {
    engine: ScriptEngine,
    /// The currently loaded script registry.  `None` until
    /// [`handle_set_directory`] succeeds for the first time.
    registry: Option<ScriptRegistry>,
    /// Per-feed compile errors keyed by `feed_id`.
    /// Populated alongside registry compiled feeds; cleared and rebuilt on
    /// every reload.
    load_errors: HashMap<String, String>,
    /// Live tasks keyed by `request_id`.  Each entry holds a cancellation
    /// token (to request cooperative shutdown) and a join handle (for cleanup).
    tasks: HashMap<String, (CancellationToken, JoinHandle<()>)>,
    /// Pending feed installs awaiting user confirmation, keyed by `request_id`.
    /// Maps to the raw Lua script content returned by the preview step.
    pending_installs: HashMap<String, String>,
}

impl FeedActor {
    pub fn new(engine: ScriptEngine) -> Self {
        Self {
            engine,
            registry: None,
            load_errors: HashMap::new(),
            tasks: HashMap::new(),
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
    /// confirmation signal is sent to Dart. Feeds that fail to compile are
    /// kept as unavailable entries; their errors are reported in the `error`
    /// field of the signal.
    /// On registry-load failure the **old state is kept** (degraded-mode
    /// protection) and an error signal is sent.
    pub async fn handle_set_directory(&mut self, req: SetScriptDirectory) {
        if self.registry.is_some() {
            ScriptDirectorySet {
                success: false,
                feed_count: 0,
                error: Some(t!("error.registry_reload_not_supported").to_string()),
            }
            .send_signal_to_dart();
            return;
        }
        // Create the directory (and any parents) if it does not exist yet.
        if let Err(e) = tokio::fs::create_dir_all(&req.path).await {
            ScriptDirectorySet {
                success: false,
                feed_count: 0,
                error: Some(e.to_string()),
            }
            .send_signal_to_dart();
            return;
        }

        // Ensure registry.toml exists (creates an empty one on first run).
        if let Err(e) = ScriptRegistry::ensure_registry(Path::new(&req.path)).await {
            ScriptDirectorySet {
                success: false,
                feed_count: 0,
                error: Some(localize_error(&e)),
            }
            .send_signal_to_dart();
            return;
        }

        let entries = match ScriptRegistry::load_entries(Path::new(&req.path)).await {
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

        let mut feeds = HashMap::new();
        // Eagerly compile every feed listed in the registry.
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
                ScriptDirectorySet {
                    success: false,
                    feed_count: 0,
                    error: Some(e.to_string()),
                }
                .send_signal_to_dart();
                panic!("Failed to initialize script registry: {}", e);
            }),
        );
        self.load_errors = load_errors;

        ScriptDirectorySet {
            success: error_summary.is_none(),
            feed_count,
            error: error_summary,
        }
        .send_signal_to_dart();
    }

    /// Enumerate all feeds in the current registry and send the list to Dart.
    pub fn handle_list_feeds(&self, req: ListFeedsRequest) {
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
        let Some(registry) = self.registry.as_ref() else {
            emit_end(
                request_id,
                FeedStreamStatus::Failed,
                Some(t!("error.script_dir_not_set").to_string()),
            );
            return None;
        };
        if let Some((_, feed)) = registry.feed(feed_id) {
            return Some(Arc::clone(feed));
        }

        let msg = if registry.has_entry(feed_id) {
            t!("error.feed_unavailable", id = feed_id).to_string()
        } else {
            t!("error.feed_not_found", id = feed_id).to_string()
        };
        emit_end(request_id, FeedStreamStatus::Failed, Some(msg));
        None
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

        let registry = match self.registry.as_mut() {
            Some(registry) => registry,
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

        // Persist script, load feed, and update in-memory map atomically.
        let entry = match registry.install_feed(&content, &self.engine).await {
            Ok(e) => e,
            Err(e) => {
                FeedInstallResult {
                    request_id: req.request_id,
                    success: false,
                    error: Some(localize_error(&e)),
                }
                .send_signal_to_dart();
                return;
            }
        };

        // Installation succeeded; clear stale load error for this feed.
        self.load_errors.remove(&entry.id);

        FeedInstallResult {
            request_id: req.request_id,
            success: true,
            error: None,
        }
        .send_signal_to_dart();
    }

    /// Remove an installed feed and update both in-memory state and disk.
    pub async fn handle_remove(&mut self, req: RemoveFeedRequest) {
        let registry = match self.registry.as_mut() {
            Some(registry) => registry,
            None => {
                FeedRemoveResult {
                    request_id: req.request_id,
                    success: false,
                    error: Some(t!("error.script_dir_not_set").to_string()),
                }
                .send_signal_to_dart();
                return;
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
                .send_signal_to_dart();
            }
            Err(e) => {
                FeedRemoveResult {
                    request_id: req.request_id,
                    success: false,
                    error: Some(localize_error(&e)),
                }
                .send_signal_to_dart();
            }
        }
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
                reg.has_entry(&meta.id),
                reg.entry(&meta.id).map(|entry| entry.version.clone()),
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
                        emit_end(&request_id, FeedStreamStatus::Failed, Some(localize_error(&e)));
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

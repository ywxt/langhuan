//! [`FeedActor`] — manages feed stream requests from Dart.
//!
//! # Responsibilities
//! - Accept `SearchRequest`, `ChaptersRequest`, `ChapterContentRequest` from Dart.
//! - Launch each request as an independent async task identified by `request_id`.
//! - Support concurrent in-flight requests (multiple parallel streams).
//! - Accept `FeedCancelRequest` from Dart and abort the matching task.
//! - Emit per-item signals and a terminal `FeedStreamEnd` for every request.
//! - Accept `SetScriptDirectory` from Dart to (re-)load the script registry.
//! - Accept `ListFeedsRequest` from Dart to enumerate registered feeds.
//!
//! # Script loading
//! The actor holds an optional [`ScriptRegistry`] loaded from a directory
//! supplied by Flutter.  When a feed request arrives the actor reads the
//! script from the registry asynchronously, then executes it with
//! [`ScriptEngine::load_feed`] (which uses mlua's async eval internally).
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

use crate::signals::{
    ChapterContentItem, ChapterContentRequest, ChapterInfoItem, ChaptersRequest, FeedCancelRequest,
    FeedListResult, FeedMetaItem, FeedStreamEnd, FeedStreamStatus, ListFeedsRequest,
    ScriptDirectorySet, SearchRequest, SearchResultItem, SetScriptDirectory,
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
    /// Live tasks keyed by `request_id`.  Each entry holds a cancellation
    /// token (to request cooperative shutdown) and a join handle (for cleanup).
    tasks: HashMap<String, (CancellationToken, JoinHandle<()>)>,
}

impl FeedActor {
    pub fn new(engine: ScriptEngine) -> Self {
        Self {
            engine: Arc::new(engine),
            registry: None,
            tasks: HashMap::new(),
        }
    }

    // -----------------------------------------------------------------------
    // Registry management
    // -----------------------------------------------------------------------

    /// Load (or reload) the script registry from `path`.
    ///
    /// On success the old registry is replaced and a confirmation signal is
    /// sent to Dart.  On failure the **old registry is kept** (degraded-mode
    /// protection) and an error signal is sent.
    pub async fn handle_set_directory(&mut self, req: SetScriptDirectory) {
        match ScriptRegistry::load(Path::new(&req.path)).await {
            Ok(registry) => {
                let feed_count = registry.len() as u32;
                self.registry = Some(Arc::new(registry));
                ScriptDirectorySet {
                    success: true,
                    feed_count,
                    error: None,
                }
                .send_signal_to_dart();
            }
            Err(e) => {
                ScriptDirectorySet {
                    success: false,
                    feed_count: 0,
                    error: Some(e.to_string()),
                }
                .send_signal_to_dart();
            }
        }
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
    ///
    /// The feed script is resolved (read from disk + compiled) here in the
    /// actor's own async context before spawning the stream task, so the
    /// spawned task only needs the ready-to-use [`LuaFeed`].
    pub async fn handle_search(&mut self, req: SearchRequest) {
        let request_id = req.request_id.clone();
        let Some(feed) = self.resolve_feed(&req.feed_id, &request_id).await else {
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
    pub async fn handle_chapters(&mut self, req: ChaptersRequest) {
        let request_id = req.request_id.clone();
        let Some(feed) = self.resolve_feed(&req.feed_id, &request_id).await else {
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
    pub async fn handle_chapter_content(&mut self, req: ChapterContentRequest) {
        let request_id = req.request_id.clone();
        let Some(feed) = self.resolve_feed(&req.feed_id, &request_id).await else {
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

    /// Resolve a [`LuaFeed`] for `feed_id` using the current registry and engine.
    ///
    /// Emits a `Failed` [`FeedStreamEnd`] signal and returns `None` if:
    /// - the registry has not been set yet,
    /// - `feed_id` is not found in the registry,
    /// - the script file cannot be read, or
    /// - the Lua script fails to compile/execute.
    async fn resolve_feed(&self, feed_id: &str, request_id: &str) -> Option<LuaFeed> {
        let registry = match &self.registry {
            Some(r) => Arc::clone(r),
            None => {
                emit_end(
                    request_id,
                    FeedStreamStatus::Failed,
                    Some("script directory not set".to_owned()),
                );
                return None;
            }
        };

        let script = match registry.get_script(feed_id).await {
            Ok(s) => s,
            Err(e) => {
                emit_end(request_id, FeedStreamStatus::Failed, Some(e.to_string()));
                return None;
            }
        };

        match self.engine.load_feed(&script).await {
            Ok(feed) => Some(feed),
            Err(e) => {
                emit_end(request_id, FeedStreamStatus::Failed, Some(e.to_string()));
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

async fn run_search(feed: LuaFeed, req: SearchRequest, token: CancellationToken) {
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

async fn run_chapters(feed: LuaFeed, req: ChaptersRequest, token: CancellationToken) {
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
    feed: LuaFeed,
    req: ChapterContentRequest,
    token: CancellationToken,
) {
    let stream = feed.chapter_content(&req.chapter_id);
    run_stream(req.request_id.clone(), stream, token, |content| {
        ChapterContentItem {
            request_id: req.request_id.clone(),
            title: content.title,
            paragraphs: content.paragraphs,
        }
        .send_signal_to_dart();
    })
    .await;
}

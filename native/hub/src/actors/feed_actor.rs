//! [`FeedActor`] — manages feed stream requests from Dart.
//!
//! # Responsibilities
//! - Accept `SearchRequest`, `ChaptersRequest`, `ChapterContentRequest` from Dart.
//! - Launch each request as an independent async task identified by `request_id`.
//! - Support concurrent in-flight requests (multiple parallel streams).
//! - Accept `FeedCancelRequest` from Dart and abort the matching task.
//! - Emit per-item signals and a terminal `FeedStreamEnd` for every request.
//!
//! # Retry
//! Retry with exponential back-off is handled inside `langhuan::LuaFeed`.
//! The `FeedStreamEnd.retried_count` field reflects the total retry count
//! communicated through the stream items (currently always 0 since retries
//! are transparent to the actor — extend if fine-grained visibility is needed).

use std::collections::HashMap;
use std::sync::Arc;

use langhuan::feed::Feed;
use langhuan::script::engine::ScriptEngine;
use rinf::RustSignal;
use tokio::task::JoinHandle;
use tokio_stream::StreamExt;
use tokio_util::sync::CancellationToken;

use crate::signals::{
    ChapterContentItem, ChapterContentRequest, ChapterInfoItem, ChaptersRequest, FeedCancelRequest,
    FeedStreamEnd, SearchRequest, SearchResultItem,
};

// ---------------------------------------------------------------------------
// FeedActor
// ---------------------------------------------------------------------------

/// Manages the lifecycle of all in-flight feed streams.
pub struct FeedActor {
    engine: Arc<ScriptEngine>,
    /// Live tasks keyed by `request_id`.  Each entry holds a cancellation
    /// token (to request cooperative shutdown) and a join handle (for cleanup).
    tasks: HashMap<String, (CancellationToken, JoinHandle<()>)>,
}

impl FeedActor {
    pub fn new(engine: ScriptEngine) -> Self {
        Self {
            engine: Arc::new(engine),
            tasks: HashMap::new(),
        }
    }

    // -----------------------------------------------------------------------
    // Entry-point: called from the actor's run loop
    // -----------------------------------------------------------------------

    /// Handle an incoming `SearchRequest` from Dart.
    pub fn handle_search(&mut self, req: SearchRequest) {
        let request_id = req.request_id.clone();
        let token = CancellationToken::new();
        let engine = Arc::clone(&self.engine);
        let child_token = token.clone();

        let handle = tokio::spawn(async move {
            run_search(engine, req, child_token).await;
        });

        self.register_task(request_id, token, handle);
    }

    /// Handle an incoming `ChaptersRequest` from Dart.
    pub fn handle_chapters(&mut self, req: ChaptersRequest) {
        let request_id = req.request_id.clone();
        let token = CancellationToken::new();
        let engine = Arc::clone(&self.engine);
        let child_token = token.clone();

        let handle = tokio::spawn(async move {
            run_chapters(engine, req, child_token).await;
        });

        self.register_task(request_id, token, handle);
    }

    /// Handle an incoming `ChapterContentRequest` from Dart.
    pub fn handle_chapter_content(&mut self, req: ChapterContentRequest) {
        let request_id = req.request_id.clone();
        let token = CancellationToken::new();
        let engine = Arc::clone(&self.engine);
        let child_token = token.clone();

        let handle = tokio::spawn(async move {
            run_chapter_content(engine, req, child_token).await;
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

/// Load the feed script identified by `feed_id` from the engine.
///
/// Currently a placeholder that expects a pre-registered script path
/// (in a real app you would load from storage/assets).  Returns `None`
/// and emits a `failed` end signal if the feed cannot be loaded.
fn load_feed(
    engine: &ScriptEngine,
    feed_id: &str,
    request_id: &str,
) -> Option<langhuan::script::lua_feed::LuaFeed> {
    // TODO: Replace with real script loading from disk / asset store.
    // For now, treat `feed_id` as a file path for development purposes.
    match std::fs::read_to_string(feed_id) {
        Ok(script) => match engine.load_feed(&script) {
            Ok(feed) => Some(feed),
            Err(e) => {
                FeedStreamEnd {
                    request_id: request_id.to_owned(),
                    status: "failed".to_owned(),
                    error: Some(e.to_string()),
                    retried_count: 0,
                }
                .send_signal_to_dart();
                None
            }
        },
        Err(e) => {
            FeedStreamEnd {
                request_id: request_id.to_owned(),
                status: "failed".to_owned(),
                error: Some(format!("cannot load feed script '{}': {}", feed_id, e)),
                retried_count: 0,
            }
            .send_signal_to_dart();
            None
        }
    }
}

async fn run_search(engine: Arc<ScriptEngine>, req: SearchRequest, token: CancellationToken) {
    let Some(feed) = load_feed(&engine, &req.feed_id, &req.request_id) else {
        return;
    };

    let mut stream: langhuan::feed::FeedStream<'_, langhuan::model::SearchResult> =
        feed.search(&req.keyword);

    loop {
        tokio::select! {
            biased;
            _ = token.cancelled() => {
                FeedStreamEnd {
                    request_id: req.request_id,
                    status: "cancelled".to_owned(),
                    error: None,
                    retried_count: 0,
                }.send_signal_to_dart();
                return;
            }
            item = stream.next() => {
                match item {
                    None => break,
                    Some(Ok(result)) => {
                        SearchResultItem {
                            request_id: req.request_id.clone(),
                            id: result.id,
                            title: result.title,
                            author: result.author,
                            cover_url: result.cover_url,
                            description: result.description,
                        }.send_signal_to_dart();
                    }
                    Some(Err(e)) => {
                        FeedStreamEnd {
                            request_id: req.request_id,
                            status: "failed".to_owned(),
                            error: Some(e.to_string()),
                            retried_count: 0,
                        }.send_signal_to_dart();
                        return;
                    }
                }
            }
        }
    }

    FeedStreamEnd {
        request_id: req.request_id,
        status: "completed".to_owned(),
        error: None,
        retried_count: 0,
    }
    .send_signal_to_dart();
}

async fn run_chapters(engine: Arc<ScriptEngine>, req: ChaptersRequest, token: CancellationToken) {
    let Some(feed) = load_feed(&engine, &req.feed_id, &req.request_id) else {
        return;
    };

    let mut stream: langhuan::feed::FeedStream<'_, langhuan::model::ChapterInfo> =
        feed.chapters(&req.book_id);

    loop {
        tokio::select! {
            biased;
            _ = token.cancelled() => {
                FeedStreamEnd {
                    request_id: req.request_id,
                    status: "cancelled".to_owned(),
                    error: None,
                    retried_count: 0,
                }.send_signal_to_dart();
                return;
            }
            item = stream.next() => {
                match item {
                    None => break,
                    Some(Ok(chapter)) => {
                        ChapterInfoItem {
                            request_id: req.request_id.clone(),
                            id: chapter.id,
                            title: chapter.title,
                            index: chapter.index,
                        }.send_signal_to_dart();
                    }
                    Some(Err(e)) => {
                        FeedStreamEnd {
                            request_id: req.request_id,
                            status: "failed".to_owned(),
                            error: Some(e.to_string()),
                            retried_count: 0,
                        }.send_signal_to_dart();
                        return;
                    }
                }
            }
        }
    }

    FeedStreamEnd {
        request_id: req.request_id,
        status: "completed".to_owned(),
        error: None,
        retried_count: 0,
    }
    .send_signal_to_dart();
}

async fn run_chapter_content(
    engine: Arc<ScriptEngine>,
    req: ChapterContentRequest,
    token: CancellationToken,
) {
    let Some(feed) = load_feed(&engine, &req.feed_id, &req.request_id) else {
        return;
    };

    let mut stream: langhuan::feed::FeedStream<'_, langhuan::model::ChapterContent> =
        feed.chapter_content(&req.chapter_id);

    loop {
        tokio::select! {
            biased;
            _ = token.cancelled() => {
                FeedStreamEnd {
                    request_id: req.request_id,
                    status: "cancelled".to_owned(),
                    error: None,
                    retried_count: 0,
                }.send_signal_to_dart();
                return;
            }
            item = stream.next() => {
                match item {
                    None => break,
                    Some(Ok(content)) => {
                        ChapterContentItem {
                            request_id: req.request_id.clone(),
                            title: content.title,
                            paragraphs: content.paragraphs,
                        }.send_signal_to_dart();
                    }
                    Some(Err(e)) => {
                        FeedStreamEnd {
                            request_id: req.request_id,
                            status: "failed".to_owned(),
                            error: Some(e.to_string()),
                            retried_count: 0,
                        }.send_signal_to_dart();
                        return;
                    }
                }
            }
        }
    }

    FeedStreamEnd {
        request_id: req.request_id,
        status: "completed".to_owned(),
        error: None,
        retried_count: 0,
    }
    .send_signal_to_dart();
}

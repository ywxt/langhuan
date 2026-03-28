//! [`StreamActor`] — manages feed stream requests from Dart.
//!
//! # Responsibilities
//! - Accept `SearchRequest`, `ChaptersRequest`, `ChapterContentRequest` from Dart.
//! - Launch each request as an independent async task identified by `request_id`.
//! - Support concurrent in-flight requests (multiple parallel streams).
//! - Accept `FeedCancelRequest` from Dart and abort the matching task.
//! - Emit per-item signals and a terminal `FeedStreamEnd` for every request.
//!
//! # Feed resolution
//! The actor does not own the script registry.  Instead it holds an
//! [`Address<RegistryActor>`] and sends a [`GetFeed`] handler message to
//! resolve a pre-compiled [`LuaFeed`] on demand.

use std::sync::Arc;

use async_trait::async_trait;
use langhuan::feed::Feed;
use langhuan::script::lua_feed::LuaFeed;
use messages::prelude::{Actor, Address, Context, Notifiable};
use rinf::{DartSignal, RustSignal};
use tokio::task::JoinSet;
use tokio_stream::StreamExt;
use tokio_util::task::JoinMap;

use crate::localize_error;
use crate::signals::{
    ChapterContentRequest, ChapterInfoItem, ChapterParagraphItem, ChaptersRequest,
    FeedCancelRequest, FeedStreamEnd, FeedStreamStatus, ParagraphContent, SearchRequest,
    SearchResultItem,
};

use super::registry_actor::{GetFeed, RegistryActor};

// ---------------------------------------------------------------------------
// StreamActor
// ---------------------------------------------------------------------------

/// Manages the lifecycle of all in-flight feed streams.
pub struct StreamActor {
    /// Address of the [`RegistryActor`] used to resolve feeds.
    registry_addr: Address<RegistryActor>,
    /// Live stream tasks keyed by `request_id`.
    /// Inserting a duplicate key automatically aborts the previous task.
    stream_tasks: JoinMap<String, ()>,
    /// Owned tasks that are canceled when the actor is dropped.
    _owned_tasks: JoinSet<()>,
}

impl Actor for StreamActor {}

impl StreamActor {
    /// Creates the actor and spawns listener tasks for all stream-related
    /// Dart signal types.
    pub fn new(self_addr: Address<Self>, registry_addr: Address<RegistryActor>) -> Self {
        let mut _owned_tasks = JoinSet::new();
        _owned_tasks.spawn(Self::listen_to_search(self_addr.clone()));
        _owned_tasks.spawn(Self::listen_to_chapters(self_addr.clone()));
        _owned_tasks.spawn(Self::listen_to_chapter_content(self_addr.clone()));
        _owned_tasks.spawn(Self::listen_to_cancel(self_addr));
        Self {
            registry_addr,
            stream_tasks: JoinMap::new(),
            _owned_tasks,
        }
    }

    // -----------------------------------------------------------------------
    // Stream request handlers
    // -----------------------------------------------------------------------

    /// Handle an incoming `SearchRequest` from Dart.
    async fn do_search(&mut self, req: SearchRequest) {
        let request_id = req.request_id.clone();
        let Some(feed) = self.resolve_feed(&req.feed_id, &request_id).await else {
            return;
        };

        self.stream_tasks.spawn(request_id, async move {
            run_search(feed, req).await;
        });
    }

    /// Handle an incoming `ChaptersRequest` from Dart.
    async fn do_chapters(&mut self, req: ChaptersRequest) {
        let request_id = req.request_id.clone();
        let Some(feed) = self.resolve_feed(&req.feed_id, &request_id).await else {
            return;
        };

        self.stream_tasks.spawn(request_id, async move {
            run_chapters(feed, req).await;
        });
    }

    /// Handle an incoming `ChapterContentRequest` from Dart.
    async fn do_chapter_content(&mut self, req: ChapterContentRequest) {
        let request_id = req.request_id.clone();
        let Some(feed) = self.resolve_feed(&req.feed_id, &request_id).await else {
            return;
        };

        self.stream_tasks.spawn(request_id, async move {
            run_chapter_content(feed, req).await;
        });
    }

    /// Cancel the task identified by `request_id`, if it is still running.
    fn do_cancel(&mut self, req: FeedCancelRequest) -> Option<FeedStreamEnd> {
        self.stream_tasks
            .abort(&req.request_id)
            .then_some(FeedStreamEnd {
                request_id: req.request_id,
                status: FeedStreamStatus::Cancelled,
                error: None,
                retried_count: 0,
            })
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    /// Resolve a pre-compiled [`LuaFeed`] by sending a [`GetFeed`] message to
    /// the [`RegistryActor`].
    ///
    /// Emits a `Failed` [`FeedStreamEnd`] and returns `None` on error.
    async fn resolve_feed(&mut self, feed_id: &str, request_id: &str) -> Option<Arc<LuaFeed>> {
        let result = self
            .registry_addr
            .send(GetFeed {
                feed_id: feed_id.to_owned(),
            })
            .await;

        match result {
            Ok(Ok(feed)) => Some(feed),
            Ok(Err(e)) => {
                emit_end(request_id, FeedStreamStatus::Failed, Some(e.to_string()));
                None
            }
            Err(e) => {
                // Actor mailbox error — should not happen in normal operation.
                emit_end(
                    request_id,
                    FeedStreamStatus::Failed,
                    Some(format!("internal error: {e}")),
                );
                None
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Notifiable impls
// ---------------------------------------------------------------------------

#[async_trait]
impl Notifiable<SearchRequest> for StreamActor {
    async fn notify(&mut self, msg: SearchRequest, _: &Context<Self>) {
        self.do_search(msg).await;
    }
}

#[async_trait]
impl Notifiable<ChaptersRequest> for StreamActor {
    async fn notify(&mut self, msg: ChaptersRequest, _: &Context<Self>) {
        self.do_chapters(msg).await;
    }
}

#[async_trait]
impl Notifiable<ChapterContentRequest> for StreamActor {
    async fn notify(&mut self, msg: ChapterContentRequest, _: &Context<Self>) {
        self.do_chapter_content(msg).await;
    }
}

#[async_trait]
impl Notifiable<FeedCancelRequest> for StreamActor {
    async fn notify(&mut self, msg: FeedCancelRequest, _: &Context<Self>) {
        if let Some(signal) = self.do_cancel(msg) {
            signal.send_signal_to_dart();
        }
    }
}

// ---------------------------------------------------------------------------
// Dart signal listeners
// ---------------------------------------------------------------------------

impl StreamActor {
    async fn listen_to_search(mut self_addr: Address<Self>) {
        let receiver = SearchRequest::get_dart_signal_receiver();
        while let Some(signal_pack) = receiver.recv().await {
            let _ = self_addr.notify(signal_pack.message).await;
        }
    }

    async fn listen_to_chapters(mut self_addr: Address<Self>) {
        let receiver = ChaptersRequest::get_dart_signal_receiver();
        while let Some(signal_pack) = receiver.recv().await {
            let _ = self_addr.notify(signal_pack.message).await;
        }
    }

    async fn listen_to_chapter_content(mut self_addr: Address<Self>) {
        let receiver = ChapterContentRequest::get_dart_signal_receiver();
        while let Some(signal_pack) = receiver.recv().await {
            let _ = self_addr.notify(signal_pack.message).await;
        }
    }

    async fn listen_to_cancel(mut self_addr: Address<Self>) {
        let receiver = FeedCancelRequest::get_dart_signal_receiver();
        while let Some(signal_pack) = receiver.recv().await {
            let _ = self_addr.notify(signal_pack.message).await;
        }
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
async fn run_stream<T, F>(
    request_id: String,
    mut stream: langhuan::feed::FeedStream<'_, T>,
    mut emit_item: F,
) where
    F: FnMut(T),
{
    while let Some(item) = stream.next().await {
        match item {
            Ok(value) => emit_item(value),
            Err(e) => {
                emit_end(
                    &request_id,
                    FeedStreamStatus::Failed,
                    Some(localize_error(&e)),
                );
                return;
            }
        }
    }
    emit_end(&request_id, FeedStreamStatus::Completed, None);
}

async fn run_search(feed: Arc<LuaFeed>, req: SearchRequest) {
    let stream = feed.search(&req.keyword);
    run_stream(req.request_id.clone(), stream, |result| {
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

async fn run_chapters(feed: Arc<LuaFeed>, req: ChaptersRequest) {
    let stream = feed.chapters(&req.book_id);
    run_stream(req.request_id.clone(), stream, |chapter| {
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

async fn run_chapter_content(feed: Arc<LuaFeed>, req: ChapterContentRequest) {
    use langhuan::model::Paragraph;

    let stream = feed.paragraphs(&req.chapter_id);
    run_stream(req.request_id.clone(), stream, |paragraph| {
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

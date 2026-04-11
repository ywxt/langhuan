//! [`StreamActor`] — handles feed queries: book info and pull-based streams.
//!
//! The generic [`PullStream<T>`] encapsulates a spawned producer task that
//! iterates a feed stream and sends items through a bounded channel.  Dart
//! calls `next()` to pull one item at a time.

use std::sync::Arc;

use async_trait::async_trait;
use langhuan::cache::CachedFeed;
use langhuan::feed::Feed;
use langhuan::model::Paragraph;
use langhuan::script::lua::LuaFeed;
use messages::prelude::{Actor, Address, Context, Handler};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio_stream::StreamExt;

use crate::api::types::{
    BookInfo, BridgeError, ChapterItem, ParagraphContent, SearchResultItem,
};

use super::registry_actor::{GetFeed, RegistryActor};

// ---------------------------------------------------------------------------
// Generic pull-based stream
// ---------------------------------------------------------------------------

/// A pull-based stream backed by a bounded channel and a spawned producer task.
///
/// The producer iterates the underlying feed stream and sends mapped items
/// through the channel.  On the first error the producer terminates.
pub struct PullStream<T: Send + 'static> {
    rx: mpsc::Receiver<Result<T, BridgeError>>,
    _task: JoinHandle<()>,
}

impl<T: Send + 'static> PullStream<T> {
    /// Pull the next item.  Returns `Ok(None)` when the stream is exhausted.
    pub async fn next(&mut self) -> Result<Option<T>, BridgeError> {
        match self.rx.recv().await {
            Some(Ok(item)) => Ok(Some(item)),
            Some(Err(e)) => Err(e),
            None => Ok(None),
        }
    }

    /// Cancel the stream: abort the producer task and close the channel.
    ///
    /// After calling this, subsequent `next()` calls will return `Ok(None)`.
    pub fn cancel(&mut self) {
        self._task.abort();
        self.rx.close();
    }
}

/// Spawn a producer task that iterates `stream`, maps each `Ok` item through
/// `map_fn`, and sends the result into a bounded channel (capacity 1).
///
/// The task terminates when the stream is exhausted, the receiver is dropped,
/// or the first error is encountered.
///
/// `make_stream` receives a `mpsc::Sender` and is responsible for iterating
/// the feed stream inside the spawned task (so owned data can be moved in).
fn spawn_pull_stream<T, F, Fut>(make_producer: F) -> PullStream<T>
where
    T: Send + 'static,
    F: FnOnce(mpsc::Sender<Result<T, BridgeError>>) -> Fut,
    Fut: std::future::Future<Output = ()> + Send + 'static,
{
    let (tx, rx) = mpsc::channel(1);
    let task = tokio::spawn(make_producer(tx));
    PullStream { rx, _task: task }
}

/// Helper: iterate a feed stream, map each item, and send through the channel.
/// Terminates on stream exhaustion, receiver drop, or first error.
async fn drive_stream<S, SrcItem, T, F>(
    stream: S,
    tx: mpsc::Sender<Result<T, BridgeError>>,
    map_fn: F,
) where
    S: tokio_stream::Stream<Item = Result<SrcItem, langhuan::error::Error>>,
    T: Send + 'static,
    F: Fn(SrcItem) -> T,
{
    tokio::pin!(stream);
    while let Some(result) = stream.next().await {
        let item = match result {
            Ok(src) => Ok(map_fn(src)),
            Err(e) => Err(BridgeError::from(e)),
        };
        let is_err = item.is_err();
        if tx.send(item).await.is_err() {
            break; // receiver dropped
        }
        if is_err {
            break; // terminate stream on error
        }
    }
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

pub struct GetBookInfo {
    pub feed_id: String,
    pub book_id: String,
}

pub struct OpenSearchStream {
    pub feed_id: String,
    pub keyword: String,
}

pub struct OpenChaptersStream {
    pub feed_id: String,
    pub book_id: String,
}

pub struct OpenParagraphsStream {
    pub feed_id: String,
    pub book_id: String,
    pub chapter_id: String,
}

// ---------------------------------------------------------------------------
// Actor
// ---------------------------------------------------------------------------

pub struct StreamActor {
    registry_addr: Address<RegistryActor>,
}

impl Actor for StreamActor {}

impl StreamActor {
    pub fn new(registry_addr: Address<RegistryActor>) -> Self {
        Self { registry_addr }
    }

    async fn resolve_feed(
        &mut self,
        feed_id: &str,
    ) -> Result<Arc<CachedFeed<LuaFeed>>, BridgeError> {
        let result = self
            .registry_addr
            .send(GetFeed {
                feed_id: feed_id.to_owned(),
            })
            .await;

        match result {
            Ok(Ok(feed)) => Ok(feed),
            Ok(Err(e)) => Err(BridgeError::from(e.to_string())),
            Err(e) => Err(BridgeError::from(e)),
        }
    }
}

// ---------------------------------------------------------------------------
// Handler impls
// ---------------------------------------------------------------------------

#[async_trait]
impl Handler<GetBookInfo> for StreamActor {
    type Result = Result<BookInfo, BridgeError>;

    async fn handle(&mut self, msg: GetBookInfo, _: &Context<Self>) -> Self::Result {
        tracing::debug!(feed_id = %msg.feed_id, book_id = %msg.book_id, "book info");
        let feed = self.resolve_feed(&msg.feed_id).await?;
        let info = feed
            .book_info(&msg.book_id)
            .await
            .map_err(BridgeError::from)?;
        Ok(BookInfo {
            id: info.id,
            title: info.title,
            author: info.author,
            cover_url: info.cover_url,
            description: info.description,
        })
    }
}

#[async_trait]
impl Handler<OpenSearchStream> for StreamActor {
    type Result = Result<PullStream<SearchResultItem>, BridgeError>;

    async fn handle(&mut self, msg: OpenSearchStream, _: &Context<Self>) -> Self::Result {
        tracing::debug!(feed_id = %msg.feed_id, keyword = %msg.keyword, "open search stream");
        let feed = self.resolve_feed(&msg.feed_id).await?;
        let keyword = msg.keyword;
        Ok(spawn_pull_stream(|tx| async move {
            drive_stream(feed.search(&keyword), tx, |item| SearchResultItem {
                id: item.id,
                title: item.title,
                author: item.author,
                cover_url: item.cover_url,
                description: item.description,
            })
            .await
        }))
    }
}

#[async_trait]
impl Handler<OpenChaptersStream> for StreamActor {
    type Result = Result<PullStream<ChapterItem>, BridgeError>;

    async fn handle(&mut self, msg: OpenChaptersStream, _: &Context<Self>) -> Self::Result {
        tracing::debug!(feed_id = %msg.feed_id, book_id = %msg.book_id, "open chapters stream");
        let feed = self.resolve_feed(&msg.feed_id).await?;
        let book_id = msg.book_id;
        Ok(spawn_pull_stream(|tx| async move {
            drive_stream(feed.chapters(&book_id), tx, |item| ChapterItem {
                id: item.id,
                title: item.title,
                index: item.index,
            })
            .await
        }))
    }
}

#[async_trait]
impl Handler<OpenParagraphsStream> for StreamActor {
    type Result = Result<PullStream<ParagraphContent>, BridgeError>;

    async fn handle(&mut self, msg: OpenParagraphsStream, _: &Context<Self>) -> Self::Result {
        tracing::debug!(
            feed_id = %msg.feed_id,
            book_id = %msg.book_id,
            chapter_id = %msg.chapter_id,
            "open paragraphs stream"
        );
        let feed = self.resolve_feed(&msg.feed_id).await?;
        let book_id = msg.book_id;
        let chapter_id = msg.chapter_id;
        Ok(spawn_pull_stream(|tx| async move {
            drive_stream(
                feed.paragraphs(&book_id, &chapter_id),
                tx,
                |paragraph| match paragraph {
                    Paragraph::Title { text } => ParagraphContent::Title { text },
                    Paragraph::Text { content } => ParagraphContent::Text { content },
                    Paragraph::Image { url, alt } => ParagraphContent::Image { url, alt },
                },
            )
            .await
        }))
    }
}

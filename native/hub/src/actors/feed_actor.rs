//! [`FeedActor`] — handles feed queries.
//!
//! Search remains pull-based because callers consume and cancel it
//! incrementally. Finite chapter and paragraph queries are collected in a
//! background task and returned as one value.

use std::{
    future::Future,
    sync::Arc,
    time::{Duration, Instant},
};

use async_trait::async_trait;
use langhuan::cache::CachedFeed;
use langhuan::feed::Feed;
use langhuan::script::feed::ScriptFeed;
use messages::prelude::{Actor, Address, Context, Handler};
use tokio::sync::Semaphore;
use tokio::sync::mpsc;
use tokio::task::{JoinHandle, JoinSet};
use tokio_stream::StreamExt;

use crate::api::types::{
    AggregatedSearchEvent, BookInfo, BridgeError, ChapterItem, FeedMetaItem, ParagraphContent,
    SearchResultItem,
};

use super::app_data_actor::InitializeAppDataDirectory;
use super::registry_actor::{GetFeed, ListFeeds, RegistryActor};
use crate::api::transformers::{TransformerConfigurationStore, build_transform_chain};

// ---------------------------------------------------------------------------
// Generic pull-based stream
// ---------------------------------------------------------------------------

/// A pull-based stream backed by a bounded channel and a spawned producer task.
///
/// The producer iterates the underlying feed stream and sends mapped items
/// through the channel.  On the first error the producer terminates.
pub struct PullStream<T: Send + 'static> {
    state: tokio::sync::Mutex<PullState<T>>,
    _task: JoinHandle<()>,
    cancelled: std::sync::atomic::AtomicBool,
    cancellation: tokio::sync::Notify,
}

struct PullState<T> {
    rx: mpsc::Receiver<Result<T, BridgeError>>,
    pending_error: Option<BridgeError>,
}

/// A finite feed query running outside the actor mailbox.
///
/// The wrapper keeps Tokio's task type and join-error mapping out of message
/// handlers' callers while allowing the actor to accept the next request as
/// soon as the query has been started.
pub struct FeedQueryTask<T> {
    operation: &'static str,
    task: JoinHandle<Result<T, BridgeError>>,
}

impl<T: Send + 'static> FeedQueryTask<T> {
    fn spawn<F>(operation: &'static str, future: F) -> Self
    where
        F: Future<Output = Result<T, BridgeError>> + Send + 'static,
    {
        Self {
            operation,
            task: tokio::spawn(future),
        }
    }

    pub async fn resolve(self) -> Result<T, BridgeError> {
        self.task.await.map_err(|error| {
            BridgeError::from(format!("{} task failed: {error}", self.operation))
        })?
    }
}

impl<T: Send + 'static> PullStream<T> {
    /// Only readers take the state lock. Cancellation stays independent of
    /// both this lock and the bridge's shared opaque-object access.
    async fn read_next(&self, state: &mut PullState<T>) -> Result<Option<T>, BridgeError> {
        use std::sync::atomic::Ordering;
        let cancelled = self.cancellation.notified();
        tokio::pin!(cancelled);
        cancelled.as_mut().enable();
        if self.cancelled.load(Ordering::Acquire) {
            return Ok(None);
        }
        if let Some(error) = state.pending_error.take() {
            return Err(error);
        }
        tokio::select! {
            _ = &mut cancelled => Ok(None),
            value = state.rx.recv() => match value {
                Some(Ok(item)) => Ok(Some(item)), Some(Err(e)) => Err(e), None => Ok(None),
            }
        }
    }

    pub async fn next(&self) -> Result<Option<T>, BridgeError> {
        self.read_next(&mut *self.state.lock().await).await
    }

    /// Return a bounded batch. Preserve any items received before a terminal
    /// error, delivering that error on the following pull instead of dropping
    /// a partially filled batch.
    pub async fn next_batch(&self, limit: usize) -> Result<Option<Vec<T>>, BridgeError> {
        assert!(limit > 0);
        let mut state = self.state.lock().await;
        let mut items = Vec::with_capacity(limit);
        let mut deadline = None;
        while items.len() < limit {
            // Wait for the first event, then bound coalescing latency. A slow
            // source must not hold results already available from other feeds.
            let next = if let Some(deadline) = deadline {
                match tokio::time::timeout_at(deadline, self.read_next(&mut state)).await {
                    Ok(next) => next,
                    Err(_) => break,
                }
            } else {
                self.read_next(&mut state).await
            };
            match next {
                Ok(Some(item)) => {
                    items.push(item);
                    deadline.get_or_insert_with(|| {
                        tokio::time::Instant::now() + Duration::from_millis(40)
                    });
                }
                Ok(None) => break,
                Err(error) if items.is_empty() => return Err(error),
                Err(error) => {
                    state.pending_error = Some(error);
                    break;
                }
            }
        }
        if self.cancelled.load(std::sync::atomic::Ordering::Acquire) {
            return Ok(None);
        }
        Ok((!items.is_empty()).then_some(items))
    }

    /// Wake pending readers and abort the producer without waiting for a pull.
    pub fn cancel(&self) {
        self.cancelled
            .store(true, std::sync::atomic::Ordering::Release);
        self._task.abort();
        self.cancellation.notify_waiters();
    }
}

impl<T: Send + 'static> Drop for PullStream<T> {
    fn drop(&mut self) {
        self._task.abort();
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
pub(crate) fn spawn_pull_stream<T, F, Fut>(make_producer: F) -> PullStream<T>
where
    T: Send + 'static,
    F: FnOnce(mpsc::Sender<Result<T, BridgeError>>) -> Fut,
    Fut: std::future::Future<Output = ()> + Send + 'static,
{
    let (tx, rx) = mpsc::channel(1);
    let task = tokio::spawn(make_producer(tx));
    PullStream {
        state: tokio::sync::Mutex::new(PullState {
            rx,
            pending_error: None,
        }),
        _task: task,
        cancelled: std::sync::atomic::AtomicBool::new(false),
        cancellation: tokio::sync::Notify::new(),
    }
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
    pub force_refresh: bool,
}

pub struct OpenSearchStream {
    pub feed_id: String,
    pub keyword: String,
}

pub struct OpenAggregatedSearchStream {
    pub keyword: String,
}

pub struct GetChapters {
    pub feed_id: String,
    pub book_id: String,
    pub force_refresh: bool,
}

pub struct GetParagraphs {
    pub feed_id: String,
    pub book_id: String,
    pub chapter_id: String,
    pub force_refresh: bool,
}

// ---------------------------------------------------------------------------
// Actor
// ---------------------------------------------------------------------------

/// Upper bound on feed searches running at once, shared across every
/// aggregated search in the session. Each search drives a sandbox runtime plus
/// its network I/O; without a cap, a keyword fired across a dozen feeds
/// would light them all up simultaneously.
const MAX_CONCURRENT_FEED_SEARCHES: usize = 4;

pub struct FeedActor {
    registry_addr: Address<RegistryActor>,
    search_permits: Arc<Semaphore>,
    transformer_store: Option<TransformerConfigurationStore>,
}

impl Actor for FeedActor {}

impl FeedActor {
    pub fn new(registry_addr: Address<RegistryActor>) -> Self {
        Self::with_search_permits(
            registry_addr,
            Arc::new(Semaphore::new(MAX_CONCURRENT_FEED_SEARCHES)),
        )
    }

    /// Like [`FeedActor::new`], but the search permit pool is owned by the
    /// caller — used by tests to observe the bound deterministically.
    pub fn with_search_permits(
        registry_addr: Address<RegistryActor>,
        search_permits: Arc<Semaphore>,
    ) -> Self {
        Self {
            registry_addr,
            search_permits,
            transformer_store: None,
        }
    }

    async fn resolve_feed(
        &mut self,
        feed_id: &str,
    ) -> Result<Arc<CachedFeed<ScriptFeed>>, BridgeError> {
        let result = self
            .registry_addr
            .send(GetFeed {
                feed_id: feed_id.to_owned(),
            })
            .await;

        match result {
            Ok(Ok(feed)) => Ok(feed),
            Ok(Err(e)) => Err(e.into()),
            Err(e) => Err(BridgeError::from(e)),
        }
    }
}

// ---------------------------------------------------------------------------
// Handler impls
// ---------------------------------------------------------------------------

#[async_trait]
impl Handler<InitializeAppDataDirectory> for FeedActor {
    type Result = Result<(), BridgeError>;
    async fn handle(&mut self, msg: InitializeAppDataDirectory, _: &Context<Self>) -> Self::Result {
        self.transformer_store = Some(TransformerConfigurationStore::new(msg.db));
        Ok(())
    }
}

#[async_trait]
impl Handler<GetBookInfo> for FeedActor {
    type Result = Result<BookInfo, BridgeError>;

    async fn handle(&mut self, msg: GetBookInfo, _: &Context<Self>) -> Self::Result {
        tracing::debug!(feed_id = %msg.feed_id, book_id = %msg.book_id, force_refresh = msg.force_refresh, "book info");
        let feed = self.resolve_feed(&msg.feed_id).await?;
        let info = feed
            .book_info_with_options(&msg.book_id, msg.force_refresh)
            .await
            .map_err(BridgeError::from)?;
        Ok(BookInfo::from(info))
    }
}

#[async_trait]
impl Handler<OpenSearchStream> for FeedActor {
    type Result = Result<PullStream<SearchResultItem>, BridgeError>;

    async fn handle(&mut self, msg: OpenSearchStream, _: &Context<Self>) -> Self::Result {
        tracing::debug!(feed_id = %msg.feed_id, keyword = %msg.keyword, "open search stream");
        let feed = self.resolve_feed(&msg.feed_id).await?;
        let keyword = msg.keyword;
        Ok(spawn_pull_stream(|tx| async move {
            drive_stream(feed.search(&keyword), tx, SearchResultItem::from).await
        }))
    }
}

#[async_trait]
impl Handler<OpenAggregatedSearchStream> for FeedActor {
    type Result = Result<PullStream<AggregatedSearchEvent>, BridgeError>;

    async fn handle(&mut self, msg: OpenAggregatedSearchStream, _: &Context<Self>) -> Self::Result {
        tracing::debug!(keyword = %msg.keyword, "open aggregated search stream");
        let all_feeds: Vec<FeedMetaItem> = self
            .registry_addr
            .send(ListFeeds)
            .await
            .map_err(BridgeError::from)?;

        // Paused feeds never take part in aggregated search.
        let feeds: Vec<FeedMetaItem> = all_feeds.into_iter().filter(|f| f.enabled).collect();

        // One producer task per feed, all feeding a single merged channel.
        // The actor mailbox only serialises the opening, so the searches
        // themselves run concurrently. A failure in one feed surfaces as a
        // FeedError event for that feed instead of ending the stream; only
        // the initial registry listing can fail the whole request.
        let registry = self.registry_addr.clone();
        let permits = self.search_permits.clone();
        let keyword = msg.keyword;
        Ok(spawn_pull_stream(move |tx| async move {
            let mut tasks = JoinSet::new();
            for meta in feeds {
                let tx = tx.clone();
                let registry = registry.clone();
                let permits = permits.clone();
                let keyword = keyword.clone();
                tasks.spawn(
                    async move { search_one_feed(registry, tx, permits, meta, keyword).await },
                );
            }
            // The merged channel closes once every per-feed sender drops.
            drop(tx);
            while tasks.join_next().await.is_some() {}
        }))
    }
}

/// Resolve one feed and drive its search into the merged channel,
/// isolating both resolution and search failures to that feed.
async fn search_one_feed(
    mut registry: Address<RegistryActor>,
    tx: mpsc::Sender<Result<AggregatedSearchEvent, BridgeError>>,
    permits: Arc<Semaphore>,
    meta: FeedMetaItem,
    keyword: String,
) {
    // Bound how many feeds are searched at once. Waiting feeds hold their
    // producer task and start as soon as an in-flight search finishes; the
    // semaphore is never closed, so the acquire cannot fail.
    let permit = permits
        .acquire()
        .await
        .expect("search permit semaphore is never closed");

    // Flatten the messaging + resolution results so either failure kind is
    // reported for this feed alone.
    let feed = match registry
        .send(GetFeed {
            feed_id: meta.id.clone(),
        })
        .await
        .map_err(|e| e.to_string())
        .and_then(|inner| inner.map_err(|e| e.to_string()))
    {
        Ok(feed) => feed,
        Err(e) => {
            drop(permit);
            emit_feed_error(&tx, &meta, e).await;
            return;
        }
    };
    drop(permit);

    let stream = feed.search(&keyword);
    tokio::pin!(stream);
    loop {
        // Tokio's fair semaphore queues each advance separately. Never hold
        // a slot while waiting for Flutter to consume a result, or throughout
        // every page of one source: either can starve queued sources.
        let permit = permits.acquire().await.expect("search semaphore is open");
        let result = stream.next().await;
        drop(permit);
        let Some(result) = result else { break };
        let event = match result {
            Ok(item) => AggregatedSearchEvent::Item {
                feed_id: meta.id.clone(),
                feed_name: meta.name.clone(),
                item: SearchResultItem::from(item),
            },
            Err(e) => AggregatedSearchEvent::FeedError {
                feed_id: meta.id.clone(),
                feed_name: meta.name.clone(),
                error: e.to_string(),
            },
        };
        let is_feed_error = matches!(event, AggregatedSearchEvent::FeedError { .. });
        if tx.send(Ok(event)).await.is_err() {
            break; // receiver dropped (stream cancelled)
        }
        if is_feed_error {
            break; // this feed's contribution is done
        }
    }
}

async fn emit_feed_error(
    tx: &mpsc::Sender<Result<AggregatedSearchEvent, BridgeError>>,
    meta: &FeedMetaItem,
    error: String,
) {
    let _ = tx
        .send(Ok(AggregatedSearchEvent::FeedError {
            feed_id: meta.id.clone(),
            feed_name: meta.name.clone(),
            error,
        }))
        .await;
}

#[async_trait]
impl Handler<GetChapters> for FeedActor {
    type Result = Result<FeedQueryTask<Vec<ChapterItem>>, BridgeError>;

    async fn handle(&mut self, msg: GetChapters, _: &Context<Self>) -> Self::Result {
        tracing::debug!(feed_id = %msg.feed_id, book_id = %msg.book_id, force_refresh = msg.force_refresh, "get chapters");
        let feed = self.resolve_feed(&msg.feed_id).await?;
        if msg.force_refresh {
            feed.clear_chapters_cache(&msg.book_id).await?;
        }
        let feed_id = msg.feed_id;
        let book_id = msg.book_id;
        Ok(FeedQueryTask::spawn("chapter", async move {
            let started = Instant::now();
            let stream = feed.chapters(&book_id);
            tokio::pin!(stream);
            let mut items = Vec::new();
            while let Some(item) = stream.next().await {
                let item = match item {
                    Ok(item) => item,
                    Err(error) => {
                        tracing::warn!(
                            feed_id = %feed_id,
                            book_id = %book_id,
                            elapsed_ms = started.elapsed().as_millis(),
                            error = %error,
                            "chapter query failed"
                        );
                        return Err(BridgeError::from(error));
                    }
                };
                items.push(ChapterItem::from(item));
            }
            tracing::debug!(
                feed_id = %feed_id,
                book_id = %book_id,
                item_count = items.len(),
                elapsed_ms = started.elapsed().as_millis(),
                "chapter query completed"
            );
            Ok(items)
        }))
    }
}

#[async_trait]
impl Handler<GetParagraphs> for FeedActor {
    type Result = Result<FeedQueryTask<Vec<ParagraphContent>>, BridgeError>;

    async fn handle(&mut self, msg: GetParagraphs, _: &Context<Self>) -> Self::Result {
        tracing::debug!(
            feed_id = %msg.feed_id,
            book_id = %msg.book_id,
            chapter_id = %msg.chapter_id,
            force_refresh = msg.force_refresh,
            "get paragraphs"
        );
        let feed = self.resolve_feed(&msg.feed_id).await?;
        let rules = self
            .transformer_store
            .as_ref()
            .ok_or_else(BridgeError::not_initialized)?
            .rules_for_book(&msg.feed_id, &msg.book_id)
            .await?;
        let mut transform_chain = build_transform_chain(rules)?;
        if msg.force_refresh {
            feed.clear_chapter_cache(&msg.book_id, &msg.chapter_id)
                .await?;
        }

        let feed_id = msg.feed_id;
        let book_id = msg.book_id;
        let chapter_id = msg.chapter_id;

        transform_chain.init(&chapter_id);
        Ok(FeedQueryTask::spawn("paragraph", async move {
            let started = Instant::now();
            let stream = feed.paragraphs(&book_id, &chapter_id);
            tokio::pin!(stream);
            let mut items = Vec::new();
            while let Some(paragraph) = stream.next().await {
                let paragraph = match paragraph {
                    Ok(paragraph) => paragraph,
                    Err(error) => {
                        tracing::warn!(
                            feed_id = %feed_id,
                            book_id = %book_id,
                            chapter_id = %chapter_id,
                            elapsed_ms = started.elapsed().as_millis(),
                            error = %error,
                            "paragraph query failed"
                        );
                        return Err(BridgeError::from(error));
                    }
                };
                if transform_chain.is_empty() {
                    items.push(ParagraphContent::from(paragraph));
                } else {
                    items.extend(
                        transform_chain
                            .apply(paragraph)
                            .into_iter()
                            .map(ParagraphContent::from),
                    );
                }
            }
            tracing::debug!(
                feed_id = %feed_id,
                book_id = %book_id,
                chapter_id = %chapter_id,
                item_count = items.len(),
                elapsed_ms = started.elapsed().as_millis(),
                "paragraph query completed"
            );
            Ok(items)
        }))
    }
}

// ---------------------------------------------------------------------------
// Tests — aggregated search over mockito-backed fixture feeds
// ---------------------------------------------------------------------------

#[cfg(test)]
mod pull_batch_tests {
    use super::spawn_pull_stream;
    use crate::api::types::BridgeError;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use tokio::sync::Notify;

    #[tokio::test]
    async fn cancellation_wakes_a_batch_waiting_for_its_first_result() {
        let stream = Arc::new(spawn_pull_stream::<u8, _, _>(|_tx| async {
            std::future::pending::<()>().await;
        }));
        let reader = stream.clone();
        let pending = tokio::spawn(async move { reader.next_batch(20).await });
        tokio::task::yield_now().await;
        stream.cancel();
        assert!(
            tokio::time::timeout(std::time::Duration::from_secs(1), pending)
                .await
                .expect("cancel must interrupt an active pull")
                .unwrap()
                .unwrap()
                .is_none()
        );
    }

    #[tokio::test]
    async fn available_results_do_not_wait_for_a_slow_source() {
        let resume = Arc::new(Notify::new());
        let signal = resume.clone();
        let stream = spawn_pull_stream(|tx| async move {
            tx.send(Ok(1)).await.unwrap();
            signal.notified().await;
            tx.send(Ok(2)).await.unwrap();
        });
        assert_eq!(
            tokio::time::timeout(std::time::Duration::from_secs(1), stream.next_batch(20))
                .await
                .expect("partial batch must not wait for the producer")
                .expect("batch"),
            Some(vec![1])
        );
        resume.notify_one();
        assert_eq!(
            stream.next_batch(20).await.expect("resumed batch"),
            Some(vec![2])
        );
        assert!(stream.next_batch(20).await.expect("end").is_none());
    }

    #[tokio::test]
    async fn batches_preserve_order_and_return_the_final_partial_batch() {
        let stream = spawn_pull_stream(|tx| async move {
            for value in 0..45 {
                if tx.send(Ok(value)).await.is_err() {
                    return;
                }
            }
        });
        for expected in [0..20, 20..40, 40..45] {
            assert_eq!(
                stream.next_batch(20).await.expect("batch"),
                Some(expected.collect::<Vec<_>>())
            );
        }
        assert!(stream.next_batch(20).await.expect("end").is_none());
    }

    #[tokio::test]
    async fn an_error_after_results_is_deferred_without_losing_the_results() {
        let stream = spawn_pull_stream(|tx| async move {
            let _ = tx.send(Ok(1)).await;
            let _ = tx.send(Ok(2)).await;
            let _ = tx
                .send(Err(BridgeError::from("failed page".to_owned())))
                .await;
        });
        assert_eq!(
            stream.next_batch(20).await.expect("partial batch"),
            Some(vec![1, 2])
        );
        assert!(
            stream
                .next_batch(20)
                .await
                .expect_err("deferred error")
                .message
                .contains("failed page")
        );
        assert!(stream.next_batch(20).await.expect("end").is_none());
    }

    #[tokio::test]
    async fn cancellation_discards_buffered_items_and_stops_the_producer() {
        let ready = Arc::new(Notify::new());
        let signal = ready.clone();
        let stream = spawn_pull_stream(|tx| async move {
            let _ = tx.send(Ok(1)).await;
            signal.notify_one();
            std::future::pending::<()>().await;
        });
        ready.notified().await;
        stream.cancel();
        tokio::task::yield_now().await;
        assert!(stream._task.is_finished());
        assert!(stream.next_batch(20).await.expect("cancelled").is_none());
    }

    #[tokio::test]
    async fn dropping_the_stream_aborts_its_producer() {
        struct Aborted(Arc<AtomicBool>);
        impl Drop for Aborted {
            fn drop(&mut self) {
                self.0.store(true, Ordering::SeqCst);
            }
        }
        let aborted = Arc::new(AtomicBool::new(false));
        let guard = Aborted(aborted.clone());
        let ready = Arc::new(Notify::new());
        let signal = ready.clone();
        let stream = spawn_pull_stream::<u8, _, _>(|_tx| async move {
            let _guard = guard;
            signal.notify_one();
            std::future::pending::<()>().await;
        });
        ready.notified().await;
        drop(stream);
        tokio::task::yield_now().await;
        assert!(aborted.load(Ordering::SeqCst));
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;
    use std::error::Error;
    use std::time::Duration;

    use langhuan::db::Db;
    use langhuan::feed::FeedMeta;
    use langhuan::script::runtime::ScriptEngine;
    use messages::prelude::Context;
    use tokio::spawn;

    use super::*;
    use crate::actors::webview_actor::WebviewActor;

    type TestResult = Result<(), Box<dyn Error>>;

    /// Count-driven fixture script (same shape as the integration tests'):
    /// the search endpoint answers with a plain number and the script turns
    /// it into that many items, so a non-numeric body makes the parse fail.
    const FIXTURE_SCRIPT: &str = r#"
// ==Feed==
// @id           __ID__
// @name         __NAME__
// @version      3.0.0
// @author       hub-test
// @description  Fixture feed backed by a mockito server
// @base_url     __BASE_URL__
// @access_domain 127.0.0.1
// @schema_version 6
// ==/Feed==
import { TextDecoder } from "langhuan:encoding";
export default (() => {
  const DECODER = new TextDecoder("utf-8");
  const request = (path) => ({
    type: "request",
    request: { url: meta.base_url + path, method: "GET", headers: {} },
    next_state: { requested: true },
  });
  function search(event) {
    if (event.state == null) return request("/search");
    const count = Number(event.response ? DECODER.decode(event.response.body) : "");
    if (!Number.isInteger(count)) throw new Error("fixture: invalid search count");
    return { type: "complete", result: Array.from({ length: count }, (_, index) => ({
        id: String(1001 + index),
        title: "Fixture Book " + (index + 1),
        author: "Fixture Author",
        description: "Hermetic fixture book.",
      })) };
  }
  function bookInfo(event) {
    if (event.state == null) return request("/book/" + event.input.bookId);
    return { type: "complete", result: {
      id: "1001", title: "Fixture Book 1", author: "Fixture Author",
      description: "Hermetic fixture book.",
    } };
  }
  function chapters(event) {
    if (event.state == null) return request("/chapters/" + event.input.bookId);
    return { type: "complete", result: [] };
  }
  function paragraphs(event) {
    if (event.state == null) {
      return request("/paragraphs/" + event.input.bookId + "/" + event.input.chapterId);
    }
    return { type: "complete", result: [
      { type: "text", content: "Fixture paragraph." },
    ] };
  }
  return { search, bookInfo, chapters, paragraphs };
})();
"#;

    fn fixture_script(id: &str, name: &str, base_url: &str) -> String {
        FIXTURE_SCRIPT
            .replace("__ID__", id)
            .replace("__NAME__", name)
            .replace("__BASE_URL__", base_url)
    }

    fn meta(id: &str, name: &str, base_url: &str) -> FeedMeta {
        let mut access_domains = HashSet::new();
        access_domains.insert("127.0.0.1".to_owned());
        FeedMeta {
            id: id.to_owned(),
            name: name.to_owned(),
            version: "1.0.0".to_owned(),
            author: None,
            description: None,
            base_url: base_url.to_owned(),
            access_domains,
            schema_version: 6,
        }
    }

    /// Seed one feed (meta + script) directly through the repo layer.
    async fn seed_feed(
        db: &Db,
        id: &str,
        name: &str,
        base_url: &str,
        script: String,
    ) -> Result<(), Box<dyn Error>> {
        let feed_meta = meta(id, name, base_url);
        let feed_id = id.to_owned();
        db.write(move |repo| {
            repo.upsert_feed(&feed_meta, None, "hash", 1)?;
            repo.upsert_script(&feed_id, "1.0.0", "hash", &script, 1)
        })
        .await?;
        Ok(())
    }

    /// Spawn a registry (initialized with [db] via its handler), plus
    /// feed actor, returning the feed actor's address.
    async fn spawn_feed_actor(db: Db) -> Result<Address<FeedActor>, Box<dyn Error>> {
        spawn_feed_actor_with_permits(db, Arc::new(Semaphore::new(1))).await
    }

    /// Like [spawn_feed_actor], but the feed actor's search permit pool is
    /// owned by the test.
    async fn spawn_feed_actor_with_permits(
        db: Db,
        permits: Arc<Semaphore>,
    ) -> Result<Address<FeedActor>, Box<dyn Error>> {
        let registry_context = Context::new();
        let mut registry_addr = registry_context.address();
        let webview_context = Context::new();
        let webview_addr = webview_context.address();
        spawn(registry_context.run(RegistryActor::new(ScriptEngine::new(), webview_addr)));
        spawn(webview_context.run(WebviewActor::new()));

        registry_addr
            .send(InitializeAppDataDirectory { db: db.clone() })
            .await
            .map_err(|e| format!("messaging: {e}"))?
            .map_err(|e| format!("init: {e}"))?;

        let feed_context = Context::new();
        let mut feed_addr = feed_context.address();
        spawn(feed_context.run(FeedActor::with_search_permits(registry_addr, permits)));
        feed_addr.send(InitializeAppDataDirectory { db }).await??;
        Ok(feed_addr)
    }

    async fn collect(
        stream: PullStream<AggregatedSearchEvent>,
    ) -> Result<Vec<AggregatedSearchEvent>, BridgeError> {
        let mut events = Vec::new();
        while let Some(batch) = stream.next_batch(20).await? {
            events.extend(batch);
        }
        Ok(events)
    }

    #[tokio::test]
    async fn paragraph_actor_resolves_current_scoped_rules_and_preserves_raw_cache() -> TestResult {
        use crate::api::types::{
            BookTransformerConfiguration, TransformerConfiguration, TransformerConfigurationEntry,
            TransformerRule,
        };
        let db = Db::open_in_memory().await?;
        let mut server = mockito::Server::new_async().await;
        let request = server
            .mock("GET", "/paragraphs/book/chapter")
            .with_body("ok")
            .expect(1)
            .create_async()
            .await;
        seed_feed(
            &db,
            "fixture",
            "Fixture",
            &server.url(),
            fixture_script("fixture", "Fixture", &server.url()),
        )
        .await?;
        db.write(|repo| {
            repo.add_book("fixture", "book", "Book", "Author", None, None, 1)?;
            Ok(())
        })
        .await?;
        let replace = |pattern: &str, replacement: &str| TransformerConfigurationEntry {
            name: String::new(),
            enabled: true,
            rule: TransformerRule::RegexReplace {
                pattern: pattern.into(),
                replacement: replacement.into(),
                include_titles: false,
            },
        };
        let mut configuration = TransformerConfiguration {
            application: vec![replace("Fixture", "GLOBAL")],
            books: vec![BookTransformerConfiguration {
                feed_id: "fixture".into(),
                book_id: "book".into(),
                inherit_application: true,
                rules: vec![replace("GLOBAL", "BOOK")],
            }],
        };
        let store = TransformerConfigurationStore::new(db.clone());
        let mut actor = spawn_feed_actor(db).await?;
        for (inherit, change_global, expected) in [
            (true, false, "BOOK paragraph."),
            (false, false, "Fixture paragraph."),
            (true, true, "NEW paragraph."),
        ] {
            configuration.books[0].inherit_application = inherit;
            if change_global {
                configuration.application = vec![replace("Fixture", "NEW")];
                configuration.books[0].rules.clear();
            }
            store.save(configuration.clone()).await?;
            let task = actor
                .send(GetParagraphs {
                    feed_id: "fixture".into(),
                    book_id: "book".into(),
                    chapter_id: "chapter".into(),
                    force_refresh: false,
                })
                .await??;
            let items = task.resolve().await?;
            assert!(
                matches!(&items[..], [ParagraphContent::Text {content, ..}] if content == expected)
            );
        }
        request.assert_async().await;
        Ok(())
    }

    #[tokio::test]
    async fn aggregated_search_merges_feeds_and_isolates_failures() -> TestResult {
        let db = Db::open_in_memory().await?;

        let mut ok_server = mockito::Server::new_async().await;
        let _ok_mock = ok_server.mock("GET", "/search").with_body("2").create();
        let mut bad_server = mockito::Server::new_async().await;
        // A non-numeric body makes the fixture's search parse fail, which
        // must only fail this feed's contribution.
        let _bad_mock = bad_server
            .mock("GET", "/search")
            .with_body("not-a-number")
            .create();

        seed_feed(
            &db,
            "feed-ok",
            "Feed Ok",
            &ok_server.url(),
            fixture_script("feed-ok", "Feed Ok", &ok_server.url()),
        )
        .await?;
        seed_feed(
            &db,
            "feed-bad",
            "Feed Bad",
            &bad_server.url(),
            fixture_script("feed-bad", "Feed Bad", &bad_server.url()),
        )
        .await?;

        let mut feed_addr = spawn_feed_actor(db).await?;
        let stream = feed_addr
            .send(OpenAggregatedSearchStream {
                keyword: "kw".to_owned(),
            })
            .await
            .map_err(|e| format!("messaging: {e}"))?
            .map_err(|e| format!("open: {}", e.message))?;

        let events = collect(stream).await.map_err(|e| e.message)?;

        // The healthy feed contributes its two items, attributed correctly.
        let ok_items: Vec<&SearchResultItem> = events
            .iter()
            .filter_map(|event| match event {
                AggregatedSearchEvent::Item {
                    feed_id,
                    feed_name,
                    item,
                } if feed_id == "feed-ok" => {
                    assert_eq!(feed_name, "Feed Ok");
                    Some(item)
                }
                _ => None,
            })
            .collect();
        assert_eq!(
            ok_items
                .iter()
                .map(|item| item.id.clone())
                .collect::<Vec<_>>(),
            ["1001", "1002"],
            "both items arrive from the healthy feed"
        );

        // The failing feed reports exactly one error event, attributed too.
        let bad_errors: Vec<&str> = events
            .iter()
            .filter_map(|event| match event {
                AggregatedSearchEvent::FeedError {
                    feed_id,
                    feed_name,
                    error,
                } if feed_id == "feed-bad" => {
                    assert_eq!(feed_name, "Feed Bad");
                    Some(error.as_str())
                }
                _ => None,
            })
            .collect();
        assert_eq!(bad_errors.len(), 1, "one error event for the bad feed");
        assert!(
            bad_errors[0].contains("invalid search count"),
            "error carries the script failure: {}",
            bad_errors[0]
        );

        // Nothing else contributes and the stream ended on its own.
        assert_eq!(events.len(), 3, "2 items + 1 feed error in total");
        Ok(())
    }

    #[tokio::test]
    async fn aggregated_search_with_no_feeds_ends_immediately() -> TestResult {
        let db = Db::open_in_memory().await?;
        let mut feed_addr = spawn_feed_actor(db).await?;

        let stream = feed_addr
            .send(OpenAggregatedSearchStream {
                keyword: "kw".to_owned(),
            })
            .await
            .map_err(|e| format!("messaging: {e}"))?
            .map_err(|e| format!("open: {}", e.message))?;

        let events = collect(stream).await.map_err(|e| e.message)?;
        assert!(events.is_empty(), "no feeds, no events");
        Ok(())
    }

    #[tokio::test]
    async fn aggregated_search_skips_paused_feeds() -> TestResult {
        let db = Db::open_in_memory().await?;

        let mut paused_server = mockito::Server::new_async().await;
        let paused_mock = paused_server
            .mock("GET", "/search")
            .with_body("1")
            .expect(0)
            .create();
        let mut active_server = mockito::Server::new_async().await;
        let active_mock = active_server
            .mock("GET", "/search")
            .with_body("1")
            .expect(1)
            .create();

        seed_feed(
            &db,
            "feed-paused",
            "Feed Paused",
            &paused_server.url(),
            fixture_script("feed-paused", "Feed Paused", &paused_server.url()),
        )
        .await?;
        seed_feed(
            &db,
            "feed-active",
            "Feed Active",
            &active_server.url(),
            fixture_script("feed-active", "Feed Active", &active_server.url()),
        )
        .await?;
        db.write(|repo| repo.set_feed_enabled("feed-paused", false))
            .await?;

        let mut feed_addr = spawn_feed_actor(db).await?;
        let stream = feed_addr
            .send(OpenAggregatedSearchStream {
                keyword: "kw".to_owned(),
            })
            .await
            .map_err(|e| format!("messaging: {e}"))?
            .map_err(|e| format!("open: {}", e.message))?;

        let events = collect(stream).await.map_err(|e| e.message)?;

        let sources: Vec<&str> = events
            .iter()
            .filter_map(|event| match event {
                AggregatedSearchEvent::Item { feed_id, .. } => Some(feed_id.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(sources, ["feed-active"], "only the active feed contributes");
        assert_eq!(
            events.len(),
            1,
            "the paused feed produces neither items nor errors"
        );
        paused_mock.assert();
        active_mock.assert();
        Ok(())
    }

    #[tokio::test]
    async fn backpressure_does_not_reserve_all_search_slots() -> TestResult {
        let db = Db::open_in_memory().await?;
        let mut first = mockito::Server::new_async().await;
        let mut second = mockito::Server::new_async().await;
        let first_mock = first.mock("GET", "/search").with_body("100").create();
        let second_mock = second.mock("GET", "/search").with_body("100").create();
        for (id, url) in [("first", first.url()), ("second", second.url())] {
            seed_feed(&db, id, id, &url, fixture_script(id, id, &url)).await?;
        }
        let mut actor = spawn_feed_actor_with_permits(db, Arc::new(Semaphore::new(1))).await?;
        let stream = actor
            .send(OpenAggregatedSearchStream {
                keyword: "kw".into(),
            })
            .await
            .map_err(|e| e.to_string())?
            .map_err(|e| e.message)?;

        // Do not consume either feed's 100 results. Both first requests must
        // nevertheless start with a single search slot available.
        tokio::time::timeout(Duration::from_secs(5), async {
            while !first_mock.matched() || !second_mock.matched() {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .map_err(|_| "a source held the search slot while blocked on delivery")?;
        stream.cancel();
        Ok(())
    }

    #[tokio::test]
    async fn aggregated_search_waits_for_search_permits() -> TestResult {
        let db = Db::open_in_memory().await?;

        let mut server = mockito::Server::new_async().await;
        let mock = server
            .mock("GET", "/search")
            .with_body("1")
            .expect(1)
            .create();
        seed_feed(
            &db,
            "feed-a",
            "Feed A",
            &server.url(),
            fixture_script("feed-a", "Feed A", &server.url()),
        )
        .await?;

        // A single permit, held by the test: the actor's searches cannot
        // start while it is out, no matter how fast the source is.
        let permits = Arc::new(Semaphore::new(1));
        let permit = permits
            .clone()
            .acquire_owned()
            .await
            .map_err(|e| format!("acquire: {e}"))?;

        let mut feed_addr = spawn_feed_actor_with_permits(db, permits).await?;
        let stream = feed_addr
            .send(OpenAggregatedSearchStream {
                keyword: "kw".to_owned(),
            })
            .await
            .map_err(|e| format!("messaging: {e}"))?
            .map_err(|e| format!("open: {}", e.message))?;

        let starved = tokio::time::timeout(Duration::from_millis(150), stream.next()).await;
        assert!(
            starved.is_err(),
            "no event may arrive while the only permit is held"
        );

        drop(permit);
        let events = tokio::time::timeout(Duration::from_secs(5), collect(stream))
            .await
            .map_err(|_| "stream did not finish after the permit was released")?
            .map_err(|e| e.message)?;
        assert_eq!(
            events.len(),
            1,
            "the search resumes and yields its single item"
        );

        mock.assert();
        Ok(())
    }

    #[tokio::test]
    async fn single_feed_search_stream_reports_source_errors() -> TestResult {
        let db = Db::open_in_memory().await?;
        let mut bad_server = mockito::Server::new_async().await;
        let _bad_mock = bad_server
            .mock("GET", "/search")
            .with_body("not-a-number")
            .create();

        seed_feed(
            &db,
            "feed-bad",
            "Feed Bad",
            &bad_server.url(),
            fixture_script("feed-bad", "Feed Bad", &bad_server.url()),
        )
        .await?;

        let mut feed_addr = spawn_feed_actor(db).await?;
        let stream = feed_addr
            .send(OpenSearchStream {
                feed_id: "feed-bad".to_owned(),
                keyword: "kw".to_owned(),
            })
            .await
            .map_err(|e| format!("messaging: {e}"))?
            .map_err(|e| format!("open: {}", e.message))?;

        // The broken search surfaces as a stream error on the first pull.
        let error = match stream.next().await {
            Err(e) => e,
            Ok(_) => panic!("expected a stream error, got a value instead"),
        };
        assert!(
            error.message.contains("invalid search count"),
            "unexpected error: {}",
            error.message
        );
        Ok(())
    }
}

//! [`FeedActor`] — handles feed queries: book info and pull-based streams.
//!
//! The generic [`PullStream<T>`] encapsulates a spawned producer task that
//! iterates a feed stream and sends items through a bounded channel.  Dart
//! calls `next()` to pull one item at a time.

use std::sync::Arc;

use async_trait::async_trait;
use langhuan::cache::CachedFeed;
use langhuan::feed::Feed;
use langhuan::model::Paragraph;
use langhuan::script::feed::ScriptFeed;
use langhuan::transform::TransformChain;
use messages::prelude::{Actor, Address, Context, Handler};
use tokio::sync::Semaphore;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio_stream::StreamExt;

use crate::api::types::{
    AggregatedSearchEvent, BookInfo, BridgeError, ChapterItem, FeedMetaItem, ParagraphContent,
    ParagraphId, SearchResultItem,
};

use super::conversion_actor::{BuildTransformChain, ConversionActor};
use super::registry_actor::{GetFeed, ListFeeds, RegistryActor};

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
pub(crate) fn spawn_pull_stream<T, F, Fut>(make_producer: F) -> PullStream<T>
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

/// Like [`drive_stream`] but runs each paragraph through a [`TransformChain`].
///
/// A single input paragraph may produce zero or more output paragraphs after
/// transformation (drop / insert).
async fn drive_stream_transformed<S>(
    stream: S,
    tx: mpsc::Sender<Result<ParagraphContent, BridgeError>>,
    mut transform_chain: TransformChain,
) where
    S: tokio_stream::Stream<Item = Result<Paragraph, langhuan::error::Error>>,
{
    tokio::pin!(stream);
    while let Some(result) = stream.next().await {
        match result {
            Ok(paragraph) => {
                for p in transform_chain.apply(paragraph) {
                    let content = match p {
                        Paragraph::Title { id, text } => ParagraphContent::Title {
                            id: ParagraphId::from(id),
                            text,
                        },
                        Paragraph::Text { id, content } => ParagraphContent::Text {
                            id: ParagraphId::from(id),
                            content,
                        },
                        Paragraph::Image { id, url, alt } => ParagraphContent::Image {
                            id: ParagraphId::from(id),
                            url,
                            alt,
                        },
                    };
                    if tx.send(Ok(content)).await.is_err() {
                        return; // receiver dropped
                    }
                }
            }
            Err(e) => {
                let _ = tx.send(Err(BridgeError::from(e))).await;
                return; // terminate stream on error
            }
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

pub struct OpenChaptersStream {
    pub feed_id: String,
    pub book_id: String,
    pub force_refresh: bool,
}

pub struct OpenParagraphsStream {
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
    conversion_addr: Address<ConversionActor>,
    search_permits: Arc<Semaphore>,
}

impl Actor for FeedActor {}

impl FeedActor {
    pub fn new(
        registry_addr: Address<RegistryActor>,
        conversion_addr: Address<ConversionActor>,
    ) -> Self {
        Self::with_search_permits(
            registry_addr,
            conversion_addr,
            Arc::new(Semaphore::new(MAX_CONCURRENT_FEED_SEARCHES)),
        )
    }

    /// Like [`FeedActor::new`], but the search permit pool is owned by the
    /// caller — used by tests to observe the bound deterministically.
    pub fn with_search_permits(
        registry_addr: Address<RegistryActor>,
        conversion_addr: Address<ConversionActor>,
        search_permits: Arc<Semaphore>,
    ) -> Self {
        Self {
            registry_addr,
            conversion_addr,
            search_permits,
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
            Ok(Err(e)) => Err(BridgeError::from(e.to_string())),
            Err(e) => Err(BridgeError::from(e)),
        }
    }
}

// ---------------------------------------------------------------------------
// Handler impls
// ---------------------------------------------------------------------------

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
impl Handler<OpenSearchStream> for FeedActor {
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
            let mut tasks = Vec::with_capacity(feeds.len());
            for meta in feeds {
                let tx = tx.clone();
                let registry = registry.clone();
                let permits = permits.clone();
                let keyword = keyword.clone();
                tasks.push(tokio::spawn(async move {
                    search_one_feed(registry, tx, permits, meta, keyword).await
                }));
            }
            // The merged channel closes once every per-feed sender drops.
            drop(tx);
            for task in tasks {
                let _ = task.await;
            }
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
    let _permit = permits
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
            emit_feed_error(&tx, &meta, e).await;
            return;
        }
    };

    let stream = feed.search(&keyword);
    tokio::pin!(stream);
    while let Some(result) = stream.next().await {
        let event = match result {
            Ok(item) => AggregatedSearchEvent::Item {
                feed_id: meta.id.clone(),
                feed_name: meta.name.clone(),
                item: SearchResultItem {
                    id: item.id,
                    title: item.title,
                    author: item.author,
                    cover_url: item.cover_url,
                    description: item.description,
                },
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
impl Handler<OpenChaptersStream> for FeedActor {
    type Result = Result<PullStream<ChapterItem>, BridgeError>;

    async fn handle(&mut self, msg: OpenChaptersStream, _: &Context<Self>) -> Self::Result {
        tracing::debug!(feed_id = %msg.feed_id, book_id = %msg.book_id, force_refresh = msg.force_refresh, "open chapters stream");
        let feed = self.resolve_feed(&msg.feed_id).await?;
        if msg.force_refresh {
            feed.clear_chapters_cache(&msg.book_id).await?;
        }
        let book_id = msg.book_id;
        Ok(spawn_pull_stream(|tx| async move {
            drive_stream(feed.chapters(&book_id), tx, |item| ChapterItem {
                id: item.id,
                title: item.title,
            })
            .await
        }))
    }
}

#[async_trait]
impl Handler<OpenParagraphsStream> for FeedActor {
    type Result = Result<PullStream<ParagraphContent>, BridgeError>;

    async fn handle(&mut self, msg: OpenParagraphsStream, _: &Context<Self>) -> Self::Result {
        tracing::debug!(
            feed_id = %msg.feed_id,
            book_id = %msg.book_id,
            chapter_id = %msg.chapter_id,
            force_refresh = msg.force_refresh,
            "open paragraphs stream"
        );
        let feed = self.resolve_feed(&msg.feed_id).await?;
        if msg.force_refresh {
            feed.clear_chapter_cache(&msg.book_id, &msg.chapter_id)
                .await?;
        }

        // Build a transform chain from the current conversion settings.
        let mut transform_chain: TransformChain = self
            .conversion_addr
            .send(BuildTransformChain)
            .await
            .map_err(BridgeError::from)?;

        let book_id = msg.book_id;
        let chapter_id = msg.chapter_id;

        if transform_chain.is_empty() {
            // Fast path — no transforms, avoid per-paragraph overhead.
            Ok(spawn_pull_stream(|tx| async move {
                drive_stream(
                    feed.paragraphs(&book_id, &chapter_id),
                    tx,
                    |paragraph| match paragraph {
                        Paragraph::Title { id, text } => ParagraphContent::Title {
                            id: ParagraphId::from(id),
                            text,
                        },
                        Paragraph::Text { id, content } => ParagraphContent::Text {
                            id: ParagraphId::from(id),
                            content,
                        },
                        Paragraph::Image { id, url, alt } => ParagraphContent::Image {
                            id: ParagraphId::from(id),
                            url,
                            alt,
                        },
                    },
                )
                .await
            }))
        } else {
            // Transform path — init the chain and apply to each paragraph.
            transform_chain.init(&chapter_id);
            Ok(spawn_pull_stream(|tx| async move {
                drive_stream_transformed(
                    feed.paragraphs(&book_id, &chapter_id),
                    tx,
                    transform_chain,
                )
                .await
            }))
        }
    }
}

// ---------------------------------------------------------------------------
// Tests — aggregated search over mockito-backed fixture feeds
// ---------------------------------------------------------------------------

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
    use crate::actors::app_data_actor::InitializeAppDataDirectory;
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
// @schema_version 3
// ==/Feed==
(() => {
  const request = (path) => ({
    type: "request",
    request: { url: meta.base_url + path, method: "GET", headers: {} },
    next_state: { requested: true },
  });
  function search(event) {
    if (event.state == null) return request("/search");
    const count = Number(event.response?.body ?? "");
    if (!Number.isInteger(count)) throw new Error("fixture: invalid search count");
    return {
      type: "complete",
      items: Array.from({ length: count }, (_, index) => ({
        id: String(1001 + index),
        title: "Fixture Book " + (index + 1),
        author: "Fixture Author",
        description: "Hermetic fixture book.",
      })),
    };
  }
  function bookInfo(event) {
    if (event.state == null) return request("/book/" + event.input.bookId);
    return { type: "complete", value: {
      id: "1001", title: "Fixture Book 1", author: "Fixture Author",
      description: "Hermetic fixture book.",
    }};
  }
  function chapters(event) {
    if (event.state == null) return request("/chapters/" + event.input.bookId);
    return { type: "complete", items: [] };
  }
  function paragraphs(event) {
    if (event.state == null) {
      return request("/paragraphs/" + event.input.bookId + "/" + event.input.chapterId);
    }
    return { type: "complete", items: [
      { type: "text", content: "Fixture paragraph." },
    ] };
  }
  return { search, bookInfo, chapters, paragraphs };
})()
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
            schema_version: 3,
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
    /// conversion and feed actors, returning the feed actor's address.
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
        spawn(registry_context.run(RegistryActor::new(
            ScriptEngine::new(),
            webview_addr,
        )));
        spawn(webview_context.run(WebviewActor::new()));

        registry_addr
            .send(InitializeAppDataDirectory { db })
            .await
            .map_err(|e| format!("messaging: {e}"))?
            .map_err(|e| format!("init: {e}"))?;

        let conversion_context = Context::new();
        let conversion_addr = conversion_context.address();
        spawn(conversion_context.run(ConversionActor::new()));

        let feed_context = Context::new();
        let feed_addr = feed_context.address();
        spawn(feed_context.run(FeedActor::with_search_permits(
            registry_addr,
            conversion_addr,
            permits,
        )));
        Ok(feed_addr)
    }

    async fn collect(
        mut stream: PullStream<AggregatedSearchEvent>,
    ) -> Result<Vec<AggregatedSearchEvent>, BridgeError> {
        let mut events = Vec::new();
        while let Some(event) = stream.next().await? {
            events.push(event);
        }
        Ok(events)
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
        let mut stream = feed_addr
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
        let mut stream = feed_addr
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

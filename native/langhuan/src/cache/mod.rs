use std::sync::Arc;
use std::time::Duration;

use async_stream::stream;
use tokio_stream::StreamExt;

use crate::db::Db;
use crate::db::repo::CoverState;
use crate::error::Result;
use crate::feed::{
    AuthEntry, AuthInfo, AuthPageContext, AuthStatus, Feed, FeedAuthFlow, FeedMeta, FeedStream,
};
use crate::http::{FeedClient, HttpRequest, HttpResponse};
use crate::model::{BookInfo, ChapterInfo, Paragraph};

// ---------------------------------------------------------------------------
// cache_first_stream! macro — eliminates duplicated cache-first-stream pattern
// ---------------------------------------------------------------------------

/// A macro that generates a cache-first stream with the standard pattern:
///
/// 1. Try `cache_get` → on hit yield items and return.
/// 2. On error clear via `cache_clear` and fall through.
/// 3. Stream from `inner_stream`, collecting items.
/// 4. Persist via `cache_set`; on failure clear.
///
/// All expressions are evaluated inside a single `stream!` block so they can
/// borrow from the surrounding scope without ownership issues.
macro_rules! cache_first_stream {
    (
        $feed_id:expr,
        $label:expr,
        gate: $gate:expr,
        cache_get: $cache_get:expr,
        cache_clear: $cache_clear:expr,
        inner_stream: $inner_stream:expr,
        cache_set($collected:ident): $cache_set:expr
    ) => {{
        Box::pin(stream! {
            let feed_id = &$feed_id;
            let label = $label;

            // 0. Shelf gate: books not on the bookshelf never touch the
            // cache — no reads, no writes. The inner stream is served live.
            if !$gate.await {
                let mut stream = $inner_stream;
                while let Some(result) = stream.next().await {
                    yield result;
                }
                return;
            }

            // 1. Try cache
            match $cache_get {
                Ok(Some(items)) => {
                    tracing::info!(feed_id = %feed_id, items = items.len(), label, "cache hit");
                    for item in items {
                        yield Ok(item);
                    }
                    return;
                }
                Ok(None) => {
                    tracing::debug!(feed_id = %feed_id, label, "cache miss, fetching from inner feed");
                }
                Err(e) => {
                    tracing::warn!(
                        feed_id = %feed_id, label, error = %e,
                        "failed to read cache, clearing broken entry and falling back"
                    );
                    if let Err(ce) = $cache_clear {
                        tracing::warn!(feed_id = %feed_id, label, error = %ce, "failed to clear broken cache");
                    }
                }
            }

            // 2. Fetch from inner feed
            let mut $collected = Vec::new();
            let mut stream = $inner_stream;

            while let Some(result) = stream.next().await {
                match result {
                    Ok(item) => {
                        $collected.push(item.clone());
                        yield Ok(item);
                    }
                    Err(e) => {
                        tracing::warn!(feed_id = %feed_id, label, error = %e, "error from inner feed, not caching");
                        yield Err(e);
                        return;
                    }
                }
            }

            // 3. Persist to cache
            match $cache_set {
                Ok(_) => {
                    tracing::debug!(feed_id = %feed_id, label, "successfully cached");
                }
                Err(e) => {
                    tracing::warn!(feed_id = %feed_id, label, error = %e, "failed to cache, clearing entry");
                    if let Err(ce) = $cache_clear {
                        tracing::warn!(feed_id = %feed_id, label, error = %ce, "failed to clear cache after write failure");
                    }
                }
            }
        })
    }};
}

/// A proxy feed that wraps any [`Feed`] and adds SQLite-backed caching for
/// chapter lists, chapter content, and book info.
///
/// **Shelf gate**: every cache below participates only for shelved books.
/// A book not on the bookshelf is served live end-to-end — search results,
/// detail pages, reading — and nothing about it is persisted. The gate
/// applies in both directions: no cache reads and no writes, so un-shelved
/// browsing leaves no trace beyond user data (progress, bookmarks).
///
/// **Chapter content** (`paragraphs`): cache-first; cached content never
/// expires on its own (it is immutable) and is only removed by stale cleanup
/// or LRU eviction.
///
/// **Chapter lists** (`chapters`): cache-first with a TTL (lists change when
/// a book updates).
///
/// **Book info** (`book_info`): cache-first with a negative cache — once
/// fetched, the row is served from the database until a forced refresh.
/// Placeholder rows seeded from search snapshots (`info_fetched_at_ms = 0`)
/// are treated as misses so the detail page always gets full data.
///
/// **Covers**: `cover_url` is always the *remote* URL; downloaded bytes live
/// in the `covers` table and are fetched via `getCover`. Downloads run in
/// background tasks through the feed's own [`FeedClient`];
/// [`CacheRepo::claim_cover_download`] is the single decision point for
/// whether a download is due (single-flight, failure backoff, drift repair).
pub struct CachedFeed<F: Feed> {
    inner: Arc<F>,
    db: Db,
}

impl<F: Feed> CachedFeed<F> {
    /// Wrap an existing feed with database-backed caching.
    pub fn new(inner: Arc<F>, db: Db) -> Self {
        Self { inner, db }
    }

    /// Get a reference to the inner feed (useful for advanced scenarios).
    pub fn inner(&self) -> &Arc<F> {
        &self.inner
    }

    /// The shared database handle.
    pub fn db(&self) -> &Db {
        &self.db
    }

    /// Whether the book is currently shelved — the gate for all cache
    /// participation: books not on the bookshelf are served live, and nothing
    /// about them (info, chapters, paragraphs, covers) is persisted. A failed
    /// lookup fails closed.
    async fn shelved(&self, book_id: &str) -> bool {
        let feed_id = self.inner.meta().id.clone();
        let bid = book_id.to_owned();
        self.db
            .call(move |repo| repo.is_shelved(&feed_id, &bid))
            .await
            .unwrap_or(false)
    }

    /// Clear cached content for a specific chapter (force refresh).
    pub async fn clear_chapter_cache(&self, book_id: &str, chapter_id: &str) -> Result<()> {
        let feed_id = self.inner.meta().id.clone();
        let (bid, cid) = (book_id.to_owned(), chapter_id.to_owned());
        self.db
            .write(move |repo| repo.delete_paragraphs(&feed_id, &bid, &cid))
            .await
    }

    /// Clear the cached chapters list for a specific book (force refresh).
    pub async fn clear_chapters_cache(&self, book_id: &str) -> Result<()> {
        let feed_id = self.inner.meta().id.clone();
        let bid = book_id.to_owned();
        self.db
            .write(move |repo| repo.delete_chapter_list(&feed_id, &bid))
            .await
    }

    fn cached_paragraphs<'a>(
        &'a self,
        book_id: &'a str,
        chapter_id: &'a str,
    ) -> FeedStream<'a, Paragraph> {
        let feed_id = self.inner.meta().id.clone();
        let bid = book_id.to_string();
        let cid = chapter_id.to_string();
        let db = self.db.clone();
        let inner = self.inner.clone();

        cache_first_stream!(
            feed_id,
            "chapter paragraphs",
            gate: self.shelved(&bid),
            cache_get: {
                let (db, fid, b, c) = (db.clone(), feed_id.clone(), bid.clone(), cid.clone());
                db.call(move |repo| {
                    repo.get_paragraphs(&fid, &b, &c, crate::db::now_ms())
                })
                .await
            },
            cache_clear: {
                let (db, fid, b, c) = (db.clone(), feed_id.clone(), bid.clone(), cid.clone());
                db.write(move |repo| repo.delete_paragraphs(&fid, &b, &c))
                    .await
                    .map(|_| ())
            },
            inner_stream: {
                inner.paragraphs(&bid, &cid)
            },
            cache_set(collected): {
                let (db, fid, b, c) = (db.clone(), feed_id.clone(), bid.clone(), cid.clone());
                db.write(move |repo| {
                    repo.set_paragraphs(
                        &fid,
                        &b,
                        &c,
                        &collected,
                        crate::db::now_ms(),
                    )
                })
                .await
                .map(|_| ())
            }
        )
    }

    fn cached_chapters<'a>(&'a self, book_id: &'a str) -> FeedStream<'a, ChapterInfo> {
        let feed_id = self.inner.meta().id.clone();
        let bid = book_id.to_string();
        let db = self.db.clone();
        let inner = self.inner.clone();

        cache_first_stream!(
            feed_id,
            "chapter list",
            gate: self.shelved(&bid),
            cache_get: {
                let (db, fid, b) = (db.clone(), feed_id.clone(), bid.clone());
                db.call(move |repo| {
                    repo.get_chapter_list(&fid, &b, crate::db::now_ms())
                })
                .await
            },
            cache_clear: {
                let (db, fid, b) = (db.clone(), feed_id.clone(), bid.clone());
                db.write(move |repo| repo.delete_chapter_list(&fid, &b))
                    .await
                    .map(|_| ())
            },
            inner_stream: {
                inner.chapters(&bid)
            },
            cache_set(collected): {
                let (db, fid, b) = (db.clone(), feed_id.clone(), bid.clone());
                db.write(move |repo| {
                    repo.set_chapter_list(
                        &fid,
                        &b,
                        &collected,
                        crate::db::now_ms(),
                    )
                })
                .await
                .map(|_| ())
            }
        )
    }

    /// Cache-first book info with an optional forced refresh — for shelved
    /// books only; books not on the bookshelf are fetched live and never
    /// touch the database.
    ///
    /// - **Cache hit** (a row that was truly fetched, not a search-result
    ///   placeholder): serve it. The returned `cover_url` is always the
    ///   remote URL.
    /// - **Cache miss / forced**: fetch from the inner feed and persist the
    ///   row.
    ///
    /// Whenever a `cover_url` is known, a background download task is
    /// spawned; whether a download is *due* at all (single-flight, failure
    /// backoff, drift repair) is decided by the claim inside
    /// [`CoverDownloader::download`].
    pub async fn book_info_with_options(
        &self,
        book_id: &str,
        force_refresh: bool,
    ) -> Result<BookInfo> {
        let feed_id = self.inner.meta().id.clone();
        let bid = book_id.to_owned();
        let db = self.db.clone();

        // Shelf gate: books not on the bookshelf bypass the cache in both
        // directions — nothing is read, nothing is persisted, and no cover
        // download is spawned.
        if !self.shelved(&bid).await {
            return self.inner.book_info(&bid).await;
        }

        if !force_refresh {
            let hit = db
                .call({
                    let (fid, b) = (feed_id.clone(), bid.clone());
                    move |conn| {
                        Ok(conn
                            .get_book_and_touch(&fid, &b, crate::db::now_ms())?
                            .filter(|row| row.is_fetched()))
                    }
                })
                .await;

            match hit {
                Ok(Some(row)) => {
                    tracing::info!(feed_id = %feed_id, "book info cache hit");
                    if let Some(url) = row.cover_url.clone() {
                        self.spawn_cover_download(&bid, &url);
                    }
                    return Ok(row.into());
                }
                Ok(None) => {
                    tracing::debug!(feed_id = %feed_id, "book info cache miss");
                }
                Err(e) => {
                    // A read failure must not block the fetch path.
                    tracing::warn!(feed_id = %feed_id, error = %e, "failed to read book info cache");
                }
            }
        }

        // Fetch from the inner feed (source of truth).
        let info = self.inner.book_info(&bid).await?;

        // Persist; a write failure degrades to "uncached", never fails the
        // call.
        let cached = db
            .write({
                let (fid, info) = (feed_id.clone(), info.clone());
                move |repo| repo.upsert_fetched_book(&fid, &info, crate::db::now_ms())
            })
            .await;
        if let Err(e) = cached {
            tracing::warn!(feed_id = %feed_id, error = %e, "failed to cache book info");
        }

        if let Some(url) = info.cover_url.clone() {
            self.spawn_cover_download(&bid, &url);
        }

        Ok(info)
    }

    /// Spawn a background task that downloads the book's cover through the
    /// feed's own HTTP client — the same pool and `access_domains` policy as
    /// its script requests. [`CoverDownloader::download`] claims the
    /// download slot first and exits early when nothing is due.
    fn spawn_cover_download(&self, book_id: &str, url: &str) {
        let downloader = CoverDownloader::new(self.db.clone(), self.inner.http_client().clone());
        let (feed_id, bid, url) = (
            self.inner.meta().id.clone(),
            book_id.to_owned(),
            url.to_owned(),
        );
        tokio::spawn(async move {
            downloader.download(feed_id, bid, url).await;
        });
    }
}

// ---------------------------------------------------------------------------
// CoverDownloader
// ---------------------------------------------------------------------------

/// Budget for one cover download — connection, redirects, and the whole
/// body. An elapsed budget surfaces as an ordinary reqwest timeout error and
/// leaves the claim `pending` for the in-flight window to retry.
const COVER_TIMEOUT: Duration = Duration::from_secs(30);

/// Downloads cover images into the `covers` table through a feed's
/// [`FeedClient`] — the same connection pool and `access_domains` policy as
/// the feed's script requests.
///
/// Guards:
/// * **Shelf** — covers are only cached for shelved books; anything else
///   would persist data about a book the user never kept.
/// * **Domain** — the feed's `access_domains` gate the cover URL exactly
///   like script requests, and every redirect hop of the download is
///   re-checked against them.
/// * **Timeout** — [`COVER_TIMEOUT`] bounds the whole request chain.
/// * **Single-flight** — claims the download slot first; another task holding
///   a fresh `pending` claim (or a completed download) makes this a no-op.
/// * **Content type** — must be `image/*` when reported.
/// * **Size** — [`FeedClient::execute`] caps the body.
///
/// Failure semantics: network/transport errors leave the state `pending`
/// (retryable after the 10-minute in-flight window); a response that fails
/// the content checks is marked `failed` (7-day backoff). A blocked domain
/// or redirect hop is skipped before any state change, so the download
/// retries by itself once the feed's allowlist covers it.
pub struct CoverDownloader {
    db: Db,
    /// The feed's own client — the same pool and `access_domains` policy as
    /// its script requests.
    client: FeedClient,
}

impl CoverDownloader {
    pub fn new(db: Db, client: FeedClient) -> Self {
        Self { db, client }
    }

    /// Whether the book is currently shelved — covers are only cached for
    /// shelved books. A failed lookup fails closed.
    async fn shelved(&self, feed_id: &str, book_id: &str) -> bool {
        let (fid, bid) = (feed_id.to_owned(), book_id.to_owned());
        self.db
            .call(move |repo| repo.is_shelved(&fid, &bid))
            .await
            .unwrap_or(false)
    }

    /// Mark a book's cover as failed (7-day backoff before the next attempt).
    async fn mark_failed(&self, feed_id: &str, book_id: &str) {
        let (fid, bid) = (feed_id.to_owned(), book_id.to_owned());
        let _ = self
            .db
            .write(move |repo| repo.mark_cover(&fid, &bid, CoverState::Failed, crate::db::now_ms()))
            .await;
    }

    /// Download a cover image into the `covers` table. Consumes `self`:
    /// one downloader per background task.
    pub async fn download(self, feed_id: String, book_id: String, url: String) {
        if !self.shelved(&feed_id, &book_id).await {
            tracing::debug!(feed_id = %feed_id, book_id = %book_id, "cover download skipped: book not shelved");
            return;
        }

        // The feed's access_domains gate the cover URL exactly like script
        // requests — checked before any state depends on the request.
        if !self.client.allows(&url) {
            tracing::warn!(
                feed_id = %feed_id,
                book_id = %book_id,
                url = %url,
                "cover url outside access_domains; skipping download"
            );
            return;
        }

        let claimed = self
            .db
            .call({
                let (fid, bid) = (feed_id.clone(), book_id.clone());
                move |repo| repo.claim_cover_download(&fid, &bid, crate::db::now_ms())
            })
            .await
            .unwrap_or(false);
        if !claimed {
            tracing::debug!(feed_id = %feed_id, book_id = %book_id, "cover download already handled");
            return;
        }

        let request = HttpRequest::get(url);
        let resp = match self.client.execute(&feed_id, &request, COVER_TIMEOUT).await {
            Ok(resp) => resp,
            // A blocked initial URL cannot reach here (checked above), so
            // this is a redirect hop outside the allowlist. Leave the claim
            // `pending` — the download retries once the feed's allowlist
            // covers the hop.
            Err(crate::error::Error::Script(crate::error::ScriptError::DomainNotAllowed {
                host: blocked,
                ..
            })) => {
                tracing::warn!(
                    feed_id = %feed_id,
                    book_id = %book_id,
                    host = %blocked,
                    "cover redirect blocked by access_domains"
                );
                return;
            }
            // Not retryable: a cover that large will not shrink.
            Err(crate::error::Error::Script(crate::error::ScriptError::ResponseTooLarge {
                limit,
            })) => {
                tracing::debug!(feed_id = %feed_id, book_id = %book_id, limit, "cover rejected: too large");
                self.mark_failed(&feed_id, &book_id).await;
                return;
            }
            // Transient (timeout, transport): leave `pending` so the
            // in-flight window retries.
            Err(e) => {
                tracing::debug!(feed_id = %feed_id, book_id = %book_id, url = %request.url, error = %e, "cover fetch failed");
                return;
            }
        };

        self.store(feed_id, book_id, resp).await;
    }

    /// Validate the response and store it as the book's cover — the content
    /// checks that mark the cover `failed` (7-day backoff) rather than
    /// retryable.
    async fn store(self, feed_id: String, book_id: String, resp: HttpResponse) {
        let content_type = resp.content_type();
        if let Some(ct) = content_type
            .as_deref()
            .filter(|ct| !ct.starts_with("image/"))
        {
            tracing::debug!(feed_id = %feed_id, book_id = %book_id, content_type = %ct, "cover rejected: not an image");
            self.mark_failed(&feed_id, &book_id).await;
            return;
        }
        if resp.body.is_empty() {
            tracing::debug!(feed_id = %feed_id, book_id = %book_id, "cover rejected: empty body");
            self.mark_failed(&feed_id, &book_id).await;
            return;
        }

        let mime = content_type.unwrap_or_else(|| "application/octet-stream".to_owned());
        let byte_len = resp.body.len();
        let result = self
            .db
            .write({
                let (fid, bid, bytes) = (feed_id.clone(), book_id.clone(), resp.body.0);
                move |repo| repo.set_cover(&fid, &bid, &mime, &bytes[..], crate::db::now_ms())
            })
            .await;
        match result {
            Ok(()) => {
                tracing::debug!(feed_id = %feed_id, book_id = %book_id, bytes = byte_len, "cover cached");
            }
            Err(e) => {
                tracing::warn!(feed_id = %feed_id, book_id = %book_id, error = %e, "failed to store cover");
            }
        }
    }
}

impl<F: Feed> Feed for CachedFeed<F> {
    fn search<'a>(&'a self, keyword: &'a str) -> FeedStream<'a, crate::model::SearchResult> {
        // Search results are not cached (may change frequently)
        self.inner.search(keyword)
    }

    async fn book_info(&self, id: &str) -> Result<crate::model::BookInfo> {
        self.book_info_with_options(id, false).await
    }

    fn chapters<'a>(&'a self, book_id: &'a str) -> FeedStream<'a, crate::model::ChapterInfo> {
        self.cached_chapters(book_id)
    }

    fn paragraphs<'a>(
        &'a self,
        book_id: &'a str,
        chapter_id: &'a str,
    ) -> FeedStream<'a, Paragraph> {
        self.cached_paragraphs(book_id, chapter_id)
    }

    fn http_client(&self) -> &FeedClient {
        self.inner.http_client()
    }

    fn meta(&self) -> &FeedMeta {
        self.inner.meta()
    }
}

impl<F: Feed + FeedAuthFlow> FeedAuthFlow for CachedFeed<F> {
    type SupportAuth = F::SupportAuth;

    fn supports_auth(&self) -> Option<Self::SupportAuth> {
        self.inner.supports_auth()
    }

    fn auth_entry(&self, support: &Self::SupportAuth) -> Result<AuthEntry> {
        self.inner.auth_entry(support)
    }

    fn parse_auth(&self, support: &Self::SupportAuth, page: &AuthPageContext) -> Result<AuthInfo> {
        self.inner.parse_auth(support, page)
    }

    fn set_auth_info(
        &self,
        support: &Self::SupportAuth,
        auth_info: Option<AuthInfo>,
    ) -> Result<()> {
        self.inner.set_auth_info(support, auth_info)
    }

    async fn auth_status(&self, support: &Self::SupportAuth) -> Result<AuthStatus> {
        self.inner.auth_status(support).await
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use tokio_stream::StreamExt;

    use super::{CachedFeed, CoverDownloader};
    use crate::db::Db;
    use crate::db::repo::BookRow;
    use crate::error::Result;
    use crate::feed::{Feed, FeedMeta, FeedStream};
    use crate::http::FeedClient;
    use crate::model::{BookInfo, ChapterInfo, Paragraph, ParagraphId, SearchResult};

    #[test]
    fn book_row_maps_to_book_info() {
        let row = BookRow {
            feed_id: "f1".to_owned(),
            book_id: "b1".to_owned(),
            title: "T".to_owned(),
            author: "A".to_owned(),
            description: Some("D".to_owned()),
            cover_url: Some("https://cover".to_owned()),
            info_fetched_at_ms: 42,
        };
        let info = BookInfo::from(row);
        assert_eq!(info.id, "b1");
        assert_eq!(info.title, "T");
        assert_eq!(info.cover_url.as_deref(), Some("https://cover"));
    }

    // -----------------------------------------------------------------------
    // FakeFeed — a minimal in-memory feed that counts inner-fetch calls so
    // tests can prove which requests were served live versus from the cache.
    // -----------------------------------------------------------------------

    struct FakeFeed {
        meta: FeedMeta,
        client: FeedClient,
        info_fetches: AtomicUsize,
        chapter_fetches: AtomicUsize,
        paragraph_fetches: AtomicUsize,
    }

    impl FakeFeed {
        fn new(access_domains: HashSet<String>) -> Self {
            Self {
                client: FeedClient::new(&access_domains),
                meta: FeedMeta {
                    id: "fake".to_owned(),
                    name: "Fake".to_owned(),
                    version: "1.0.0".to_owned(),
                    author: None,
                    description: None,
                    base_url: "https://fake.example".to_owned(),
                    access_domains,
                    schema_version: 6,
                },
                info_fetches: AtomicUsize::new(0),
                chapter_fetches: AtomicUsize::new(0),
                paragraph_fetches: AtomicUsize::new(0),
            }
        }
    }

    impl Feed for FakeFeed {
        fn search<'a>(&'a self, _keyword: &'a str) -> FeedStream<'a, SearchResult> {
            Box::pin(tokio_stream::iter(Vec::<Result<SearchResult>>::new()))
        }

        async fn book_info(&self, id: &str) -> Result<BookInfo> {
            self.info_fetches.fetch_add(1, Ordering::SeqCst);
            Ok(BookInfo {
                id: id.to_owned(),
                title: "Title".to_owned(),
                author: "Author".to_owned(),
                cover_url: None,
                description: None,
            })
        }

        fn chapters<'a>(&'a self, book_id: &'a str) -> FeedStream<'a, ChapterInfo> {
            self.chapter_fetches.fetch_add(1, Ordering::SeqCst);
            Box::pin(tokio_stream::iter((0..2).map(move |i| {
                Ok(ChapterInfo {
                    id: format!("{book_id}-c{i}"),
                    title: format!("Chapter {i}"),
                })
            })))
        }

        fn paragraphs<'a>(
            &'a self,
            book_id: &'a str,
            chapter_id: &'a str,
        ) -> FeedStream<'a, Paragraph> {
            self.paragraph_fetches.fetch_add(1, Ordering::SeqCst);
            Box::pin(tokio_stream::iter((0..2).map(move |i| {
                Ok(Paragraph::Text {
                    id: ParagraphId::generated(i),
                    content: format!("{book_id}/{chapter_id}/{i}"),
                    layout: Default::default(),
                    comment_count: None,
                })
            })))
        }

        fn meta(&self) -> &FeedMeta {
            &self.meta
        }

        fn http_client(&self) -> &FeedClient {
            &self.client
        }
    }

    /// Open an in-memory database, register the fake feed with the given
    /// access domains, and wrap both in a [`CachedFeed`].
    async fn setup_feed(
        access_domains: HashSet<String>,
    ) -> (Db, Arc<FakeFeed>, CachedFeed<FakeFeed>) {
        let feed = FakeFeed::new(access_domains);
        let db = Db::open_in_memory().await.expect("open in-memory db");
        let meta = feed.meta.clone();
        db.write(move |repo| repo.upsert_feed(&meta, None, "test-hash", crate::db::now_ms()))
            .await
            .expect("seed feed row");
        let inner = Arc::new(feed);
        (db.clone(), inner.clone(), CachedFeed::new(inner, db))
    }

    /// Shelve a book like a real shelf-add does: the snapshot carries a
    /// `cover_url`, which the claim SQL requires before a download may run.
    async fn shelve(db: &Db, book_id: &str) {
        let bid = book_id.to_owned();
        db.write(move |repo| {
            repo.add_book(
                "fake",
                &bid,
                "Title",
                "Author",
                None,
                Some("https://fake.example/cover"),
                crate::db::now_ms(),
            )
        })
        .await
        .expect("shelve book");
    }

    async fn collect_ok<T>(mut stream: FeedStream<'_, T>) -> Vec<T> {
        let mut items = Vec::new();
        while let Some(result) = stream.next().await {
            items.push(result.expect("stream item"));
        }
        items
    }

    #[tokio::test]
    async fn shelved_books_are_served_from_the_cache() {
        let (db, inner, cached) = setup_feed(HashSet::new()).await;
        shelve(&db, "b1").await;

        for expected in [2usize, 2, 2] {
            let chapters = collect_ok(cached.chapters("b1")).await;
            let paragraphs = collect_ok(cached.paragraphs("b1", "b1-c0")).await;
            assert_eq!(chapters.len(), expected);
            assert_eq!(paragraphs.len(), expected);
        }

        // The inner feed saw exactly one round of fetches; the rest were
        // cache hits.
        assert_eq!(inner.chapter_fetches.load(Ordering::SeqCst), 1);
        assert_eq!(inner.paragraph_fetches.load(Ordering::SeqCst), 1);

        let info = cached.book_info("b1").await.expect("book info");
        assert_eq!(info.title, "Title");
        assert_eq!(inner.info_fetches.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn transforms_on_a_cache_miss_never_change_cached_source_paragraphs() {
        use crate::transform::{
            TransformChain, regex::RegexTransform, text_indent::TextIndentTransform,
        };
        let (db, inner, cached) = setup_feed(HashSet::new()).await;
        shelve(&db, "b1").await;
        let mut chain = TransformChain::new();
        chain.push(Box::new(RegexTransform::new("/1$", None, false).unwrap()));
        chain.push(Box::new(
            RegexTransform::new("b1", Some("changed".into()), false).unwrap(),
        ));
        chain.push(Box::new(TextIndentTransform::with_spaces(3)));
        let mut stream = cached.paragraphs("b1", "b1-c0");
        let mut displayed = Vec::new();
        while let Some(item) = stream.next().await {
            displayed.extend(chain.apply(item.unwrap()));
        }
        assert_eq!(displayed.len(), 1);
        assert!(
            matches!(&displayed[0], Paragraph::Text {content, layout, ..} if content == "changed/changed-c0/0" && layout.first_line_indent == 3)
        );
        let original = collect_ok(cached.paragraphs("b1", "b1-c0")).await;
        assert_eq!(original.len(), 2);
        assert!(
            matches!(&original[0], Paragraph::Text {content, layout, ..} if content == "b1/b1-c0/0" && layout.first_line_indent == 0)
        );
        assert!(matches!(&original[1], Paragraph::Text {content, ..} if content == "b1/b1-c0/1"));
        assert_eq!(inner.paragraph_fetches.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn unshelved_books_bypass_the_cache_entirely() {
        let (db, inner, cached) = setup_feed(HashSet::new()).await;

        // No shelf-add: every call must go to the inner feed, twice.
        for _ in 0..2 {
            let chapters = collect_ok(cached.chapters("b1")).await;
            let paragraphs = collect_ok(cached.paragraphs("b1", "b1-c0")).await;
            let info = cached.book_info("b1").await.expect("book info");
            assert_eq!(chapters.len(), 2);
            assert_eq!(paragraphs.len(), 2);
            assert_eq!(info.title, "Title");
        }
        assert_eq!(inner.chapter_fetches.load(Ordering::SeqCst), 2);
        assert_eq!(inner.paragraph_fetches.load(Ordering::SeqCst), 2);
        assert_eq!(inner.info_fetches.load(Ordering::SeqCst), 2);

        // Nothing about the unshelved book was persisted.
        let row = db
            .call(|repo| repo.get_book_and_touch("fake", "b1", crate::db::now_ms()))
            .await
            .expect("read books table");
        assert!(row.is_none(), "unshelved browsing must leave no books row");
        let covers = db
            .call(|repo| repo.get_cover_bytes("fake", "b1"))
            .await
            .expect("read covers table");
        assert!(covers.is_none());
    }

    #[tokio::test]
    async fn cover_downloads_skip_unshelved_books() {
        let mut server = mockito::Server::new_async().await;
        let cover = server
            .mock("GET", "/cover")
            .with_status(200)
            .with_header("content-type", "image/png")
            .with_body("png")
            .expect(0)
            .create_async()
            .await;
        let (db, inner, _cached) = setup_feed(HashSet::from(["127.0.0.1".to_owned()])).await;

        // Not shelved: skipped before any HTTP request or state change.
        CoverDownloader::new(db.clone(), inner.http_client().clone())
            .download(
                "fake".to_owned(),
                "b1".to_owned(),
                format!("{}/cover", server.url()),
            )
            .await;

        let stored = db
            .call(|repo| repo.get_cover_bytes("fake", "b1"))
            .await
            .expect("read covers table");
        assert!(stored.is_none());
        cover.assert_async().await;
    }

    #[tokio::test]
    async fn cover_downloads_require_an_allowed_domain() {
        let mut server = mockito::Server::new_async().await;
        let cover = server.mock("GET", "/cover").expect(0).create_async().await;
        // The allowlist deliberately does not cover the mock server's host.
        let (db, inner, _cached) = setup_feed(HashSet::from(["allowed.example".to_owned()])).await;
        shelve(&db, "b1").await;

        CoverDownloader::new(db.clone(), inner.http_client().clone())
            .download(
                "fake".to_owned(),
                "b1".to_owned(),
                format!("{}/cover", server.url()),
            )
            .await;

        // Skipped before the claim: no bytes, and the download slot stays
        // free for a retry once the allowlist covers the host.
        let stored = db
            .call(|repo| repo.get_cover_bytes("fake", "b1"))
            .await
            .expect("read covers table");
        assert!(stored.is_none());
        let claimed = db
            .call(|repo| repo.claim_cover_download("fake", "b1", crate::db::now_ms()))
            .await
            .expect("claim check");
        assert!(
            claimed,
            "a domain-blocked skip must not leave a pending claim"
        );
        cover.assert_async().await;
    }

    #[tokio::test]
    async fn cover_download_happy_path_stores_bytes() {
        let mut server = mockito::Server::new_async().await;
        let body = b"\x89PNG-not-really".to_vec();
        let cover = server
            .mock("GET", "/cover")
            .with_status(200)
            .with_header("content-type", "image/png")
            .with_body(body.clone())
            .expect(1)
            .create_async()
            .await;
        let (db, inner, _cached) = setup_feed(HashSet::from(["127.0.0.1".to_owned()])).await;
        shelve(&db, "b1").await;

        CoverDownloader::new(db.clone(), inner.http_client().clone())
            .download(
                "fake".to_owned(),
                "b1".to_owned(),
                format!("{}/cover", server.url()),
            )
            .await;

        let (mime, bytes) = db
            .call(|repo| repo.get_cover_bytes("fake", "b1"))
            .await
            .expect("read covers table")
            .expect("cover stored");
        assert_eq!(mime, "image/png");
        assert_eq!(bytes, body);

        // Single-flight: a completed download is a no-op, not a re-download.
        CoverDownloader::new(db.clone(), inner.http_client().clone())
            .download(
                "fake".to_owned(),
                "b1".to_owned(),
                format!("{}/cover", server.url()),
            )
            .await;
        cover.assert_async().await;
    }

    #[tokio::test]
    async fn cover_downloads_block_disallowed_redirect_hops() {
        let mut server = mockito::Server::new_async().await;
        let redirect = server
            .mock("GET", "/cover")
            .with_status(302)
            .with_header("location", "https://evil.example/land")
            .expect(1)
            .create_async()
            .await;
        let (db, inner, _cached) = setup_feed(HashSet::from(["127.0.0.1".to_owned()])).await;
        shelve(&db, "b1").await;

        CoverDownloader::new(db.clone(), inner.http_client().clone())
            .download(
                "fake".to_owned(),
                "b1".to_owned(),
                format!("{}/cover", server.url()),
            )
            .await;

        // No bytes stored, and the claim stays pending for the in-flight
        // window — a fresh claim right now must be refused.
        let stored = db
            .call(|repo| repo.get_cover_bytes("fake", "b1"))
            .await
            .expect("read covers table");
        assert!(stored.is_none());
        let claimed = db
            .call(|repo| repo.claim_cover_download("fake", "b1", crate::db::now_ms()))
            .await
            .expect("claim check");
        assert!(
            !claimed,
            "a blocked redirect hop must leave the claim pending"
        );
        redirect.assert_async().await;
    }
}

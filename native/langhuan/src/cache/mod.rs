use std::sync::Arc;

use async_stream::stream;
use tokio_stream::StreamExt;

use crate::db::Db;
use crate::db::repo::CoverState;
use crate::error::Result;
use crate::feed::{
    AuthEntry, AuthInfo, AuthPageContext, AuthStatus, Feed, FeedAuthFlow, FeedMeta, FeedStream,
};
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
        cache_get: $cache_get:expr,
        cache_clear: $cache_clear:expr,
        inner_stream: $inner_stream:expr,
        cache_set($collected:ident): $cache_set:expr
    ) => {{
        Box::pin(stream! {
            let feed_id = &$feed_id;
            let label = $label;

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

/// Upper bound for a downloaded cover image.
const MAX_COVER_BYTES: usize = 5 * 1024 * 1024;

/// A proxy feed that wraps any [`Feed`] and adds SQLite-backed caching for
/// chapter lists, chapter content, and book info.
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
/// background tasks; [`CacheRepo::claim_cover_download`] is the single
/// decision point for whether a download is due (single-flight, failure
/// backoff, drift repair).
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

    /// Cache-first book info with an optional forced refresh.
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
    /// [`download_cover`].
    pub async fn book_info_with_options(
        &self,
        book_id: &str,
        force_refresh: bool,
    ) -> Result<BookInfo> {
        let feed_id = self.inner.meta().id.clone();
        let bid = book_id.to_owned();
        let db = self.db.clone();

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
                        spawn_cover_download(db.clone(), feed_id, bid, url);
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
            spawn_cover_download(db, feed_id, bid, url);
        }

        Ok(info)
    }
}

/// Spawn the cover download task for a book; [`download_cover`] claims the
/// download slot first and exits early when nothing is due.
fn spawn_cover_download(db: Db, feed_id: String, book_id: String, url: String) {
    tokio::spawn(async move {
        download_cover(db, feed_id, book_id, url).await;
    });
}

/// Mark a book's cover as failed (7-day backoff before the next attempt).
async fn mark_cover_failed(db: &Db, feed_id: &str, book_id: &str) {
    let (fid, bid) = (feed_id.to_owned(), book_id.to_owned());
    let _ = db
        .write(move |repo| repo.mark_cover(&fid, &bid, CoverState::Failed, crate::db::now_ms()))
        .await;
}

/// Download a cover image into the `covers` table.
///
/// Guards:
/// * **Single-flight** — claims the download slot first; another task holding
///   a fresh `pending` claim (or a completed download) makes this a no-op.
/// * **Content type** — must be `image/*` when reported.
/// * **Size** — streams the body and aborts beyond [`MAX_COVER_BYTES`].
///
/// Failure semantics: network/transport errors leave the state `pending`
/// (retryable after the 10-minute in-flight window); a response that fails
/// the content checks is marked `failed` (7-day backoff).
pub async fn download_cover(db: Db, feed_id: String, book_id: String, url: String) {
    let claimed = db
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

    let resp = match crate::http::shared_client().get(&url).send().await {
        Ok(resp) => resp,
        Err(e) => {
            // Transient: leave `pending` so the in-flight window retries.
            tracing::debug!(feed_id = %feed_id, book_id = %book_id, error = %e, "cover fetch failed");
            return;
        }
    };

    let content_type = resp
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(|v| v.split(';').next().unwrap_or(v).trim().to_owned());
    if let Some(ct) = &content_type
        && !ct.starts_with("image/")
    {
        tracing::debug!(feed_id = %feed_id, book_id = %book_id, content_type = %ct, "cover rejected: not an image");
        mark_cover_failed(&db, &feed_id, &book_id).await;
        return;
    }
    if let Some(len) = resp.content_length()
        && len as usize > MAX_COVER_BYTES
    {
        tracing::debug!(feed_id = %feed_id, book_id = %book_id, length = len, "cover rejected: too large");
        mark_cover_failed(&db, &feed_id, &book_id).await;
        return;
    }

    // Stream the body with a hard cap so a lying server cannot exhaust memory.
    let mut stream = resp.bytes_stream();
    let mut buf: Vec<u8> = Vec::new();
    let mut exceeded = false;
    while let Some(chunk) = stream.next().await {
        let chunk = match chunk {
            Ok(chunk) => chunk,
            Err(e) => {
                tracing::debug!(feed_id = %feed_id, book_id = %book_id, error = %e, "cover body read failed");
                return;
            }
        };
        buf.extend_from_slice(&chunk);
        if buf.len() > MAX_COVER_BYTES {
            exceeded = true;
            break;
        }
    }
    if exceeded {
        tracing::debug!(feed_id = %feed_id, book_id = %book_id, "cover rejected: body exceeds cap");
        mark_cover_failed(&db, &feed_id, &book_id).await;
        return;
    }
    if buf.is_empty() {
        tracing::debug!(feed_id = %feed_id, book_id = %book_id, "cover rejected: empty body");
        mark_cover_failed(&db, &feed_id, &book_id).await;
        return;
    }

    let mime = content_type.unwrap_or_else(|| "application/octet-stream".to_owned());
    let byte_len = buf.len();
    let result = db
        .write({
            let (fid, bid, mime, bytes) = (feed_id.clone(), book_id.clone(), mime, buf);
            move |repo| repo.set_cover(&fid, &bid, &mime, &bytes, crate::db::now_ms())
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
    use crate::db::repo::BookRow;
    use crate::model::BookInfo;

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
}

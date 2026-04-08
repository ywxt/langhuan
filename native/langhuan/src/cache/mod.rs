use std::sync::Arc;

use async_stream::stream;
use tokio_stream::StreamExt;

use crate::error::Result;
use crate::feed::{Feed, FeedMeta, FeedStream};
use crate::model::{BookInfo, ChapterInfo, Paragraph};

pub mod models;
pub mod storage;

pub use models::{
    BookInfoCacheEntry, CACHE_SCHEMA_VERSION, ChapterCacheEntry, ChapterListCacheEntry,
};
pub use storage::CacheStore;

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

// ---------------------------------------------------------------------------
// cache_first_value! macro — cache-first for a single async value
// ---------------------------------------------------------------------------

/// Like [`cache_first_stream!`] but for a single value (e.g. `BookInfo`).
///
/// * `cache_get`   – expression evaluating to `Result<Option<T>>`
/// * `cache_clear` – expression evaluating to `Result<()>`
/// * `inner_fetch` – expression evaluating to `Result<T>`
/// * `cache_set`   – expression (with `$value` in scope) evaluating to `Result<()>`
///
/// An optional `is_valid($v)` guard can reject a cache hit (treat as miss).
/// An optional `post_fetch($v)` block runs after a successful inner fetch
/// (e.g. to spawn background work). It must **not** be awaited on the hot path.
macro_rules! cache_first_value {
    (
        $feed_id:expr,
        $label:expr,
        cache_get: $cache_get:expr,
        cache_clear: $cache_clear:expr,
        $(is_valid($cv:ident): $is_valid:expr,)?
        $(on_hit($hv:ident): $on_hit:expr,)?
        inner_fetch: $inner_fetch:expr,
        cache_set($sv:ident): $cache_set:expr
        $(, post_fetch($pv:ident): $post_fetch:expr)?
    ) => {{
        let feed_id = &$feed_id;
        let label = $label;

        let mut _miss = false;

        // 1. Try cache
        match $cache_get {
            Ok(Some(value)) => {
                // Optional validity check
                let valid = true $(&& { let $cv = &value; $is_valid })?;
                if valid {
                    tracing::info!(feed_id = %feed_id, label, "cache hit");
                    #[allow(unused_mut)]
                    let mut value = value;
                    $( { let $hv = &mut value; $on_hit; } )?
                    return Ok(value);
                } else {
                    tracing::debug!(feed_id = %feed_id, label, "cache hit but validity check failed, treating as miss");
                    _miss = true;
                }
            }
            Ok(None) => {
                tracing::debug!(feed_id = %feed_id, label, "cache miss, fetching from inner feed");
                _miss = true;
            }
            Err(e) => {
                tracing::warn!(
                    feed_id = %feed_id, label, error = %e,
                    "failed to read cache, clearing broken entry and falling back"
                );
                if let Err(ce) = $cache_clear {
                    tracing::warn!(feed_id = %feed_id, label, error = %ce, "failed to clear broken cache");
                }
                _miss = true;
            }
        }

        // 2. Fetch from inner feed
        let value = $inner_fetch?;

        // 3. Persist to cache
        {
            let $sv = &value;
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
        }

        // 4. Optional post-fetch hook
        $( { let $pv = &value; $post_fetch; } )?

        Ok(value)
    }};
}

/// A proxy feed that wraps any [`Feed`] and adds caching for chapter content.
///
/// **Cache-first behavior for paragraphs():**
/// - First attempts to load from cache store
/// - If cache hit: returns cached paragraphs as a stream (no network call)
/// - If cache miss: calls inner feed, streams paragraphs, then persists to cache on completion
///
/// **Other methods**:
/// - `search()` is passed through without caching.
/// - `book_info()` is cache-first.
///
/// # Example
///
/// ```ignore
/// let lua_feed = Arc::new(lua_feed);
/// let cache_store = Arc::new(CacheStore::new(cache_dir));
/// let cached_feed = CachedFeed::new(lua_feed, cache_store);
///
/// // All paragraphs() calls now use cache-first
/// for para in cached_feed.paragraphs("book-001", "ch-001") { ... }
/// ```
pub struct CachedFeed<F: Feed> {
    inner: Arc<F>,
    cache_store: Arc<CacheStore>,
}

impl<F: Feed> CachedFeed<F> {
    /// Wrap an existing feed with caching.
    pub fn new(inner: Arc<F>, cache_store: Arc<CacheStore>) -> Self {
        Self { inner, cache_store }
    }

    /// Get a reference to the inner feed (useful for advanced scenarios).
    pub fn inner(&self) -> &Arc<F> {
        &self.inner
    }

    /// Get a reference to the cache store (useful for cache management).
    pub fn cache_store(&self) -> &Arc<CacheStore> {
        &self.cache_store
    }

    /// Clear cached content for a specific chapter.
    pub async fn clear_chapter_cache(&self, book_id: &str, chapter_id: &str) -> Result<()> {
        self.cache_store
            .clear_chapter(&self.inner.meta().id, book_id, chapter_id)
            .await
    }

    /// Clear cached content for a specific book.
    pub async fn clear_book_cache(&self, book_id: &str) -> Result<()> {
        self.cache_store
            .clear_book(&self.inner.meta().id, book_id)
            .await
    }

    /// Clear all cached content for this feed.
    pub async fn clear_cache(&self) -> Result<()> {
        self.cache_store.clear_feed(&self.inner.meta().id).await
    }

    fn cached_paragraphs<'a>(
        &'a self,
        book_id: &'a str,
        chapter_id: &'a str,
    ) -> FeedStream<'a, Paragraph> {
        let feed_id = self.inner.meta().id.clone();
        let bid = book_id.to_string();
        let cid = chapter_id.to_string();
        let cs = self.cache_store.clone();
        let inner = self.inner.clone();

        cache_first_stream!(
            feed_id,
            "chapter paragraphs",
            cache_get: {
                cs.get_chapter(&feed_id, &bid, &cid)
                    .await
                    .map(|opt| opt.map(|e| e.paragraphs))
            },
            cache_clear: {
                cs.clear_chapter(&feed_id, &bid, &cid).await
            },
            inner_stream: {
                inner.paragraphs(&bid, &cid)
            },
            cache_set(collected): {
                let entry = ChapterCacheEntry::new(
                    feed_id.clone(), bid.clone(), cid.clone(), collected,
                );
                cs.set_chapter(&entry).await
            }
        )
    }

    fn cached_chapters<'a>(&'a self, book_id: &'a str) -> FeedStream<'a, ChapterInfo> {
        let feed_id = self.inner.meta().id.clone();
        let bid = book_id.to_string();
        let cs = self.cache_store.clone();
        let inner = self.inner.clone();

        cache_first_stream!(
            feed_id,
            "chapter list",
            cache_get: {
                cs.get_chapters(&feed_id, &bid)
                    .await
                    .map(|opt| opt.map(|e| e.chapters))
            },
            cache_clear: {
                cs.clear_chapters(&feed_id, &bid).await
            },
            inner_stream: {
                inner.chapters(&bid)
            },
            cache_set(collected): {
                let entry = ChapterListCacheEntry::new(
                    feed_id.clone(), bid.clone(), collected,
                );
                cs.set_chapters(&entry).await
            }
        )
    }

    /// Cache-first book info.
    ///
    /// - **Cache hit**: return cached `BookInfo`. If the cover file is missing
    ///   on disk, treat as a cache miss so the cover gets re-downloaded.
    /// - **Cache miss**: fetch from inner feed, return the original `BookInfo`
    ///   immediately (no blocking on cover download), then spawn a background
    ///   task to download the cover image and save it locally.
    ///
    /// On subsequent cache hits the `cover_url` is rewritten to the local path.
    async fn cached_book_info(&self, book_id: &str) -> Result<BookInfo> {
        let feed_id = self.inner.meta().id.clone();
        let bid = book_id.to_string();
        let cs = self.cache_store.clone();

        cache_first_value!(
            feed_id,
            "book info",
            cache_get: {
                cs.get_book_info(&feed_id, &bid)
                    .await
                    .map(|opt| opt.map(|e| e.book_info))
            },
            cache_clear: {
                cs.clear_book_info(&feed_id, &bid).await
            },
            // Reject cache hit when cover_url is set but the local file is missing.
            is_valid(v): {
                v.cover_url.is_none()
                    || cs.cover_local_path(&feed_id, &bid).is_some()
            },
            // On valid cache hit, rewrite cover_url to local path.
            on_hit(v): {
                if let Some(local) = cs.cover_local_path(&feed_id, &bid) {
                    v.cover_url = Some(local.to_string_lossy().into_owned());
                }
            },
            inner_fetch: {
                self.inner.book_info(&bid).await
            },
            cache_set(v): {
                let entry = BookInfoCacheEntry::new(
                    feed_id.clone(), bid.clone(), v.clone(),
                );
                cs.set_book_info(&entry).await
            },
            // Spawn background cover download after returning.
            post_fetch(v): {
                if let Some(url) = &v.cover_url {
                    let cs = cs.clone();
                    let fid = feed_id.clone();
                    let bid = bid.clone();
                    let url = url.clone();
                    tokio::spawn(async move {
                        download_cover_to_cache(&cs, &fid, &bid, &url).await;
                    });
                }
            }
        )
    }
}

/// Download a cover image from `url` and save it to the cache store.
async fn download_cover_to_cache(
    cache_store: &CacheStore,
    feed_id: &str,
    book_id: &str,
    url: &str,
) {
    let resp = match reqwest::get(url).await {
        Ok(r) => r,
        Err(e) => {
            tracing::debug!(
                feed_id = %feed_id,
                book_id = %book_id,
                cover_url = %url,
                error = %e,
                "failed to fetch cover image"
            );
            return;
        }
    };

    let bytes = match resp.bytes().await {
        Ok(b) => b,
        Err(e) => {
            tracing::debug!(
                feed_id = %feed_id,
                book_id = %book_id,
                cover_url = %url,
                error = %e,
                "failed to read cover bytes"
            );
            return;
        }
    };

    match cache_store.save_cover(feed_id, book_id, &bytes).await {
        Ok(path) => {
            tracing::debug!(
                feed_id = %feed_id,
                book_id = %book_id,
                path = %path.display(),
                "cover image cached in background"
            );
        }
        Err(e) => {
            tracing::warn!(
                feed_id = %feed_id,
                book_id = %book_id,
                error = %e,
                "failed to save cover to cache"
            );
        }
    }
}

impl<F: Feed> Feed for CachedFeed<F> {
    fn search<'a>(&'a self, keyword: &'a str) -> FeedStream<'a, crate::model::SearchResult> {
        // Search results are not cached (may change frequently)
        self.inner.search(keyword)
    }

    async fn book_info(&self, id: &str) -> Result<crate::model::BookInfo> {
        self.cached_book_info(id).await
    }

    fn chapters<'a>(&'a self, book_id: &'a str) -> FeedStream<'a, crate::model::ChapterInfo> {
        self.cached_chapters(book_id)
    }

    fn paragraphs<'a>(&'a self, book_id: &'a str, chapter_id: &'a str) -> FeedStream<'a, Paragraph> {
        self.cached_paragraphs(book_id, chapter_id)
    }

    fn meta(&self) -> &FeedMeta {
        self.inner.meta()
    }
}

#[cfg(test)]
mod tests {
    // Note: Full integration tests for CachedFeed are complex due to the Feed trait.
    // The CacheStore is tested separately in storage.rs with concrete tests.
    // CachedFeed will be tested at the hub/actors level where concrete Feed types are used.
}

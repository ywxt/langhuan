use std::path::{Path, PathBuf};

use serde::Serialize;
use serde::de::DeserializeOwned;

use crate::error::{
    CacheKeyMismatchError, CacheSchemaMismatchError, Error, FormatKind, FormatOperation, Result,
    StorageKind, StorageOperation,
};
use crate::util::fs::write_atomic;
use crate::util::path_key::encode_path_component;

use super::models::{
    BookInfoCacheEntry, CACHE_SCHEMA_VERSION, ChapterCacheEntry, ChapterListCacheEntry,
};

/// Cache storage for chapter content.
///
/// Organizes cached chapters by
/// `<cache_dir>/<encoded_feed_id>/<encoded_book_id>/<encoded_chapter_id>.json`.
/// Each entry is stored as a JSON file containing paragraphs and metadata.
#[derive(Debug, Clone)]
pub struct CacheStore {
    cache_dir: PathBuf,
}

impl CacheStore {
    /// Create a new cache store with the given base directory.
    pub fn new(cache_dir: impl Into<PathBuf>) -> Self {
        Self {
            cache_dir: cache_dir.into(),
        }
    }

    fn feed_dir(&self, feed_id: &str) -> PathBuf {
        self.cache_dir.join(encode_path_component(feed_id))
    }

    fn book_dir(&self, feed_id: &str, book_id: &str) -> PathBuf {
        self.feed_dir(feed_id).join(encode_path_component(book_id))
    }

    /// Get the path for a cached chapter entry.
    fn chapter_cache_path(&self, feed_id: &str, book_id: &str, chapter_id: &str) -> PathBuf {
        self.book_dir(feed_id, book_id)
            .join(format!("{}.json", encode_path_component(chapter_id)))
    }

    fn chapter_list_path(&self, feed_id: &str, book_id: &str) -> PathBuf {
        self.book_dir(feed_id, book_id).join("_chapters.json")
    }

    fn book_info_path(&self, feed_id: &str, book_id: &str) -> PathBuf {
        self.book_dir(feed_id, book_id).join("_book_info.json")
    }

    fn cover_path(&self, feed_id: &str, book_id: &str) -> PathBuf {
        self.book_dir(feed_id, book_id).join("_cover")
    }

    async fn read_json_entry<T: DeserializeOwned>(&self, path: &Path) -> Result<Option<T>> {
        if !path.exists() {
            return Ok(None);
        }

        match tokio::fs::read_to_string(path).await {
            Ok(content) => serde_json::from_str::<T>(&content).map(Some).map_err(|e| {
                Error::format(
                    FormatKind::ChapterCache,
                    FormatOperation::Deserialize,
                    e.to_string(),
                )
            }),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(Error::storage(
                StorageKind::ChapterCache,
                StorageOperation::Read,
                e.to_string(),
            )),
        }
    }

    async fn write_json_entry<T: Serialize>(&self, path: &Path, entry: &T) -> Result<()> {
        if let Some(parent) = path.parent() {
            tokio::fs::create_dir_all(parent).await.map_err(|e| {
                Error::storage(
                    StorageKind::ChapterCache,
                    StorageOperation::CreateDir,
                    e.to_string(),
                )
            })?;
        }

        let content = serde_json::to_string(entry).map_err(|e| {
            Error::format(
                FormatKind::ChapterCache,
                FormatOperation::Serialize,
                e.to_string(),
            )
        })?;

        tracing::debug!(path = %path.display(), bytes = content.len(), "writing json cache entry");

        write_atomic(path, &content).await.map_err(|e| {
            tracing::warn!(path = %path.display(), error = %e, "failed to write json cache entry");
            Error::storage(
                StorageKind::ChapterCache,
                StorageOperation::Write,
                e.to_string(),
            )
        })
    }

    async fn remove_file_if_exists(&self, path: &Path) -> Result<()> {
        if path.exists() {
            tokio::fs::remove_file(path).await.map_err(|e| {
                Error::storage(
                    StorageKind::ChapterCache,
                    StorageOperation::RemoveFile,
                    e.to_string(),
                )
            })?;
        }
        Ok(())
    }

    /// Load book info from cache.
    ///
    /// Returns `Ok(None)` when the book info is not cached. Returns `Err`
    /// when an existing cache file cannot be read, parsed, or validated.
    pub async fn get_book_info(
        &self,
        feed_id: &str,
        book_id: &str,
    ) -> Result<Option<BookInfoCacheEntry>> {
        let path = self.book_info_path(feed_id, book_id);

        let maybe_entry = self.read_json_entry::<BookInfoCacheEntry>(&path).await?;
        let Some(entry) = maybe_entry else {
            tracing::debug!(
                feed_id = %feed_id,
                book_id = %book_id,
                "book info not in cache"
            );
            return Ok(None);
        };

        if entry.schema_version != CACHE_SCHEMA_VERSION {
            return Err(Error::cache_schema_mismatch(CacheSchemaMismatchError {
                feed_id: feed_id.to_string(),
                book_id: book_id.to_string(),
                chapter_id: "_book_info".to_string(),
                cached_version: entry.schema_version,
                expected_version: CACHE_SCHEMA_VERSION,
            }));
        }
        if entry.feed_id != feed_id || entry.book_id != book_id {
            return Err(Error::cache_key_mismatch(CacheKeyMismatchError {
                expected_feed_id: feed_id.to_string(),
                expected_book_id: book_id.to_string(),
                expected_chapter_id: "_book_info".to_string(),
                actual_feed_id: entry.feed_id,
                actual_book_id: entry.book_id,
                actual_chapter_id: "_book_info".to_string(),
            }));
        }

        tracing::debug!(
            feed_id = %feed_id,
            book_id = %book_id,
            "loaded book info from cache"
        );
        Ok(Some(entry))
    }

    /// Save book info to cache using atomic writes.
    pub async fn set_book_info(&self, entry: &BookInfoCacheEntry) -> Result<()> {
        let path = self.book_info_path(&entry.feed_id, &entry.book_id);
        self.write_json_entry(&path, entry).await?;

        tracing::debug!(
            feed_id = %entry.feed_id,
            book_id = %entry.book_id,
            "cached book info"
        );
        Ok(())
    }

    /// Clear cached book info and its cover for a specific book under a feed.
    pub async fn clear_book_info(&self, feed_id: &str, book_id: &str) -> Result<()> {
        let path = self.book_info_path(feed_id, book_id);
        self.remove_file_if_exists(&path).await?;
        self.clear_cover(feed_id, book_id).await?;

        tracing::debug!(feed_id = %feed_id, book_id = %book_id, "cleared book info and cover cache");
        Ok(())
    }

    /// Save cover image bytes to a local file under the book cache directory.
    ///
    /// Returns the absolute path to the saved cover file.
    pub async fn save_cover(&self, feed_id: &str, book_id: &str, bytes: &[u8]) -> Result<PathBuf> {
        let path = self.cover_path(feed_id, book_id);
        if let Some(parent) = path.parent() {
            tokio::fs::create_dir_all(parent).await.map_err(|e| {
                Error::storage(
                    StorageKind::ChapterCache,
                    StorageOperation::CreateDir,
                    e.to_string(),
                )
            })?;
        }

        tokio::fs::write(&path, bytes).await.map_err(|e| {
            tracing::warn!(
                feed_id = %feed_id,
                book_id = %book_id,
                path = %path.display(),
                error = %e,
                "failed to write cover file"
            );
            Error::storage(
                StorageKind::ChapterCache,
                StorageOperation::Write,
                e.to_string(),
            )
        })?;

        tracing::debug!(
            feed_id = %feed_id,
            book_id = %book_id,
            path = %path.display(),
            bytes = bytes.len(),
            "saved cover image to cache"
        );
        Ok(path)
    }

    /// Return the local cover file path if it exists on disk.
    pub fn cover_local_path(&self, feed_id: &str, book_id: &str) -> Option<PathBuf> {
        let path = self.cover_path(feed_id, book_id);
        if path.exists() { Some(path) } else { None }
    }

    /// Clear cached cover for a specific book under a feed.
    pub async fn clear_cover(&self, feed_id: &str, book_id: &str) -> Result<()> {
        let path = self.cover_path(feed_id, book_id);
        self.remove_file_if_exists(&path).await?;

        tracing::debug!(feed_id = %feed_id, book_id = %book_id, "cleared cover cache");
        Ok(())
    }

    /// Load a chapter list from cache.
    ///
    /// Returns `Ok(None)` when the chapter list is not cached. Returns `Err`
    /// when an existing cache file cannot be read, parsed, or validated.
    pub async fn get_chapters(
        &self,
        feed_id: &str,
        book_id: &str,
    ) -> Result<Option<ChapterListCacheEntry>> {
        let path = self.chapter_list_path(feed_id, book_id);

        let maybe_entry = self.read_json_entry::<ChapterListCacheEntry>(&path).await?;
        let Some(entry) = maybe_entry else {
            tracing::debug!(
                feed_id = %feed_id,
                book_id = %book_id,
                "chapter list not in cache"
            );
            return Ok(None);
        };

        if entry.schema_version != CACHE_SCHEMA_VERSION {
            return Err(Error::cache_schema_mismatch(CacheSchemaMismatchError {
                feed_id: feed_id.to_string(),
                book_id: book_id.to_string(),
                chapter_id: "_chapters".to_string(),
                cached_version: entry.schema_version,
                expected_version: CACHE_SCHEMA_VERSION,
            }));
        }
        if entry.feed_id != feed_id || entry.book_id != book_id {
            return Err(Error::cache_key_mismatch(CacheKeyMismatchError {
                expected_feed_id: feed_id.to_string(),
                expected_book_id: book_id.to_string(),
                expected_chapter_id: "_chapters".to_string(),
                actual_feed_id: entry.feed_id,
                actual_book_id: entry.book_id,
                actual_chapter_id: "_chapters".to_string(),
            }));
        }

        tracing::debug!(
            feed_id = %feed_id,
            book_id = %book_id,
            chapters = entry.chapters.len(),
            "loaded chapter list from cache"
        );

        Ok(Some(entry))
    }

    /// Save a chapter list to cache using atomic writes.
    pub async fn set_chapters(&self, entry: &ChapterListCacheEntry) -> Result<()> {
        let path = self.chapter_list_path(&entry.feed_id, &entry.book_id);
        self.write_json_entry(&path, entry).await?;

        tracing::debug!(
            feed_id = %entry.feed_id,
            book_id = %entry.book_id,
            chapters = entry.chapters.len(),
            "cached chapter list"
        );

        Ok(())
    }

    /// Clear cached chapter list for a specific book under a feed.
    pub async fn clear_chapters(&self, feed_id: &str, book_id: &str) -> Result<()> {
        let path = self.chapter_list_path(feed_id, book_id);
        self.remove_file_if_exists(&path).await?;

        tracing::debug!(feed_id = %feed_id, book_id = %book_id, "cleared chapter list cache");
        Ok(())
    }

    /// Load a chapter from cache.
    ///
    /// Returns `Ok(None)` when the chapter is not cached. Returns `Err` when an
    /// existing cache file cannot be read, parsed, or validated.
    pub async fn get_chapter(
        &self,
        feed_id: &str,
        book_id: &str,
        chapter_id: &str,
    ) -> Result<Option<ChapterCacheEntry>> {
        let path = self.chapter_cache_path(feed_id, book_id, chapter_id);

        let maybe_entry = self.read_json_entry::<ChapterCacheEntry>(&path).await?;
        let Some(entry) = maybe_entry else {
            tracing::debug!(
                feed_id = %feed_id,
                book_id = %book_id,
                chapter_id = %chapter_id,
                "chapter not in cache"
            );
            return Ok(None);
        };

        if entry.schema_version != CACHE_SCHEMA_VERSION {
            return Err(Error::cache_schema_mismatch(CacheSchemaMismatchError {
                feed_id: feed_id.to_string(),
                book_id: book_id.to_string(),
                chapter_id: chapter_id.to_string(),
                cached_version: entry.schema_version,
                expected_version: CACHE_SCHEMA_VERSION,
            }));
        }
        if entry.feed_id != feed_id || entry.book_id != book_id || entry.chapter_id != chapter_id {
            return Err(Error::cache_key_mismatch(CacheKeyMismatchError {
                expected_feed_id: feed_id.to_string(),
                expected_book_id: book_id.to_string(),
                expected_chapter_id: chapter_id.to_string(),
                actual_feed_id: entry.feed_id,
                actual_book_id: entry.book_id,
                actual_chapter_id: entry.chapter_id,
            }));
        }
        tracing::debug!(
            feed_id = %feed_id,
            book_id = %book_id,
            chapter_id = %chapter_id,
            paragraphs = entry.paragraphs.len(),
            "loaded chapter from cache"
        );
        Ok(Some(entry))
    }

    /// Save a chapter to cache using atomic writes.
    pub async fn set_chapter(&self, entry: &ChapterCacheEntry) -> Result<()> {
        let path = self.chapter_cache_path(&entry.feed_id, &entry.book_id, &entry.chapter_id);
        self.write_json_entry(&path, entry).await?;

        tracing::debug!(
            feed_id = %entry.feed_id,
            book_id = %entry.book_id,
            chapter_id = %entry.chapter_id,
            paragraphs = entry.paragraphs.len(),
            "cached chapter paragraphs"
        );

        Ok(())
    }

    /// Clear cache for a specific chapter.
    pub async fn clear_chapter(
        &self,
        feed_id: &str,
        book_id: &str,
        chapter_id: &str,
    ) -> Result<()> {
        let path = self.chapter_cache_path(feed_id, book_id, chapter_id);
        self.remove_file_if_exists(&path).await?;

        tracing::debug!(
            feed_id = %feed_id,
            book_id = %book_id,
            chapter_id = %chapter_id,
            "cleared chapter cache"
        );
        Ok(())
    }

    /// Clear all chapter cache for a specific book under a feed.
    pub async fn clear_book(&self, feed_id: &str, book_id: &str) -> Result<()> {
        let book_dir = self.book_dir(feed_id, book_id);
        if book_dir.exists() {
            tokio::fs::remove_dir_all(&book_dir).await.map_err(|e| {
                Error::storage(
                    StorageKind::ChapterCache,
                    StorageOperation::RemoveDir,
                    e.to_string(),
                )
            })?;
        }

        tracing::debug!(
            feed_id = %feed_id,
            book_id = %book_id,
            "cleared book cache"
        );
        Ok(())
    }

    /// Clear all cache for a feed.
    pub async fn clear_feed(&self, feed_id: &str) -> Result<()> {
        let feed_dir = self.feed_dir(feed_id);
        if feed_dir.exists() {
            tokio::fs::remove_dir_all(&feed_dir).await.map_err(|e| {
                Error::storage(
                    StorageKind::ChapterCache,
                    StorageOperation::RemoveDir,
                    e.to_string(),
                )
            })?;
        }

        tracing::debug!(feed_id = %feed_id, "cleared feed cache");
        Ok(())
    }

    /// Get cache directory path (useful for testing/management).
    pub fn cache_dir(&self) -> &PathBuf {
        &self.cache_dir
    }

    /// Remove stale book cache directories that are older than `max_age` and
    /// not in the `protected` set.
    ///
    /// Each element in `protected` is a `(feed_id, book_id)` pair whose cache
    /// must be kept regardless of age (e.g. books on the bookshelf).
    ///
    /// Staleness is determined by the newest `cached_at_ms` timestamp found
    /// in the JSON cache entry files inside each book directory.
    ///
    /// Returns the number of book directories removed.
    pub async fn cleanup_stale_books(
        &self,
        protected: &std::collections::HashSet<(String, String)>,
        max_age: std::time::Duration,
    ) -> Result<u64> {
        use crate::util::path_key::decode_path_component;
        use std::time::{SystemTime, UNIX_EPOCH};

        let cutoff_ms = (SystemTime::now() - max_age)
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);

        let mut removed = 0u64;

        if !self.cache_dir.exists() {
            return Ok(0);
        }

        let mut feed_dirs = tokio::fs::read_dir(&self.cache_dir).await.map_err(|e| {
            Error::storage(
                StorageKind::ChapterCache,
                StorageOperation::Read,
                e.to_string(),
            )
        })?;

        while let Some(feed_entry) = feed_dirs.next_entry().await.map_err(|e| {
            Error::storage(
                StorageKind::ChapterCache,
                StorageOperation::Read,
                e.to_string(),
            )
        })? {
            let feed_path = feed_entry.path();
            if !feed_path.is_dir() {
                continue;
            }
            let Some(feed_id) = feed_path
                .file_name()
                .and_then(|n| n.to_str())
                .and_then(decode_path_component)
            else {
                continue;
            };

            let Ok(mut book_dirs) = tokio::fs::read_dir(&feed_path).await else {
                continue;
            };

            while let Ok(Some(book_entry)) = book_dirs.next_entry().await {
                let book_path = book_entry.path();
                if !book_path.is_dir() {
                    continue;
                }
                let Some(book_id) = book_path
                    .file_name()
                    .and_then(|n| n.to_str())
                    .and_then(decode_path_component)
                else {
                    continue;
                };

                if protected.contains(&(feed_id.clone(), book_id.clone())) {
                    continue;
                }

                let is_stale = newest_cached_at_ms_in_dir(&book_path)
                    .await
                    .is_none_or(|ms| ms < cutoff_ms);

                if is_stale {
                    tracing::debug!(feed_id, book_id, "removing stale book cache");
                    match self.clear_book(&feed_id, &book_id).await {
                        Ok(()) => removed += 1,
                        Err(e) => {
                            tracing::warn!(feed_id, book_id, error = %e, "failed to remove stale book cache")
                        }
                    }
                }
            }

            // remove_dir only succeeds when the directory is empty.
            let _ = tokio::fs::remove_dir(&feed_path).await;
        }

        tracing::info!(removed, "cache cleanup complete");
        Ok(removed)
    }
}

/// A minimal struct used only to extract `cached_at_ms` from any JSON cache
/// entry without deserializing the full payload.
#[derive(serde::Deserialize)]
struct CachedAtProbe {
    cached_at_ms: i64,
}

/// Scan all `.json` files in a book cache directory and return the newest
/// `cached_at_ms` value found.
async fn newest_cached_at_ms_in_dir(dir: &std::path::Path) -> Option<i64> {
    let mut rd = tokio::fs::read_dir(dir).await.ok()?;
    let mut newest: Option<i64> = None;

    while let Ok(Some(entry)) = rd.next_entry().await {
        let path = entry.path();
        if path.extension().is_none_or(|ext| ext != "json") {
            continue;
        }
        if let Ok(content) = tokio::fs::read_to_string(&path).await
            && let Ok(probe) = serde_json::from_str::<CachedAtProbe>(&content)
        {
            newest =
                Some(newest.map_or(probe.cached_at_ms, |prev: i64| prev.max(probe.cached_at_ms)));
        }
    }

    newest
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::PersistenceError;
    use tempfile::TempDir;

    #[tokio::test]
    async fn test_cache_hit_and_miss() {
        let temp_dir = TempDir::new().unwrap();
        let store = CacheStore::new(temp_dir.path());

        let feed_id = "test-feed";
        let book_id = "book-001";
        let chapter_id = "ch-001";

        // Before caching: should be None
        let result = store
            .get_chapter(feed_id, book_id, chapter_id)
            .await
            .unwrap();
        assert!(result.is_none());

        // Create and cache an entry
        let entry = ChapterCacheEntry::new(
            feed_id.to_string(),
            book_id.to_string(),
            chapter_id.to_string(),
            vec![],
        );
        store.set_chapter(&entry).await.unwrap();

        // After caching: should get it back
        let cached = store
            .get_chapter(feed_id, book_id, chapter_id)
            .await
            .unwrap();
        assert!(cached.is_some());
        assert_eq!(cached.unwrap().feed_id, feed_id);
    }

    #[tokio::test]
    async fn test_clear_chapter() {
        let temp_dir = TempDir::new().unwrap();
        let store = CacheStore::new(temp_dir.path());

        let feed_id = "test-feed";
        let book_id = "book-001";
        let chapter_id = "ch-001";

        // Cache an entry
        let entry = ChapterCacheEntry::new(
            feed_id.to_string(),
            book_id.to_string(),
            chapter_id.to_string(),
            vec![],
        );
        store.set_chapter(&entry).await.unwrap();

        // Verify it's cached
        let cached = store
            .get_chapter(feed_id, book_id, chapter_id)
            .await
            .unwrap();
        assert!(cached.is_some());

        // Clear it
        store
            .clear_chapter(feed_id, book_id, chapter_id)
            .await
            .unwrap();

        // Should be gone
        let result = store
            .get_chapter(feed_id, book_id, chapter_id)
            .await
            .unwrap();
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn test_cache_chapter_list_roundtrip() {
        let temp_dir = TempDir::new().unwrap();
        let store = CacheStore::new(temp_dir.path());

        let entry = ChapterListCacheEntry::new("feed-a".to_string(), "book-1".to_string(), vec![]);

        store.set_chapters(&entry).await.unwrap();

        let loaded = store
            .get_chapters("feed-a", "book-1")
            .await
            .unwrap()
            .expect("expected stored chapter list");

        assert_eq!(loaded.feed_id, "feed-a");
        assert_eq!(loaded.book_id, "book-1");
    }

    #[tokio::test]
    async fn test_clear_chapters() {
        let temp_dir = TempDir::new().unwrap();
        let store = CacheStore::new(temp_dir.path());

        let entry = ChapterListCacheEntry::new("feed-a".to_string(), "book-1".to_string(), vec![]);

        store.set_chapters(&entry).await.unwrap();
        assert!(
            store
                .get_chapters("feed-a", "book-1")
                .await
                .unwrap()
                .is_some()
        );

        store.clear_chapters("feed-a", "book-1").await.unwrap();
        assert!(
            store
                .get_chapters("feed-a", "book-1")
                .await
                .unwrap()
                .is_none()
        );
    }

    #[tokio::test]
    async fn test_clear_book() {
        let temp_dir = TempDir::new().unwrap();
        let store = CacheStore::new(temp_dir.path());

        let first = ChapterCacheEntry::new(
            "test-feed".to_string(),
            "book-001".to_string(),
            "ch-001".to_string(),
            vec![],
        );
        let second = ChapterCacheEntry::new(
            "test-feed".to_string(),
            "book-001".to_string(),
            "ch-002".to_string(),
            vec![],
        );

        store.set_chapter(&first).await.unwrap();
        store.set_chapter(&second).await.unwrap();

        store.clear_book("test-feed", "book-001").await.unwrap();

        assert!(
            store
                .get_chapter("test-feed", "book-001", "ch-001")
                .await
                .unwrap()
                .is_none()
        );
        assert!(
            store
                .get_chapter("test-feed", "book-001", "ch-002")
                .await
                .unwrap()
                .is_none()
        );
    }

    #[tokio::test]
    async fn test_get_chapter_returns_error_for_invalid_cache() {
        let temp_dir = TempDir::new().unwrap();
        let store = CacheStore::new(temp_dir.path());
        let path = store.chapter_cache_path("test-feed", "book-001", "ch-001");

        tokio::fs::create_dir_all(path.parent().unwrap())
            .await
            .unwrap();
        write_atomic(&path, "not valid json").await.unwrap();

        let error = store
            .get_chapter("test-feed", "book-001", "ch-001")
            .await
            .expect_err("invalid cache should return an error");

        assert!(matches!(
            error,
            Error::Persistence(PersistenceError::Format {
                kind: FormatKind::ChapterCache,
                operation: FormatOperation::Deserialize,
                ..
            })
        ));
    }

    #[tokio::test]
    async fn cleanup_stale_books_removes_old_and_keeps_protected() {
        let temp_dir = TempDir::new().unwrap();
        let store = CacheStore::new(temp_dir.path());

        let twenty_days_ago_ms = {
            use std::time::{SystemTime, UNIX_EPOCH};
            let ago = SystemTime::now() - std::time::Duration::from_secs(20 * 24 * 3600);
            ago.duration_since(UNIX_EPOCH).unwrap().as_millis() as i64
        };

        // Create cache entries for 3 books.
        // book-1 and book-3 get old timestamps; book-2 stays fresh.
        let entry_a = ChapterCacheEntry {
            feed_id: "feed-a".to_string(),
            book_id: "book-1".to_string(),
            chapter_id: "ch-1".to_string(),
            paragraphs: vec![],
            cached_at_ms: twenty_days_ago_ms,
            schema_version: CACHE_SCHEMA_VERSION,
        };
        let entry_b = ChapterCacheEntry::new(
            "feed-a".to_string(),
            "book-2".to_string(),
            "ch-1".to_string(),
            vec![],
        );
        let entry_c = ChapterCacheEntry {
            feed_id: "feed-b".to_string(),
            book_id: "book-3".to_string(),
            chapter_id: "ch-1".to_string(),
            paragraphs: vec![],
            cached_at_ms: twenty_days_ago_ms,
            schema_version: CACHE_SCHEMA_VERSION,
        };
        store.set_chapter(&entry_a).await.unwrap();
        store.set_chapter(&entry_b).await.unwrap();
        store.set_chapter(&entry_c).await.unwrap();

        // Protect book-1 (on bookshelf).
        let mut protected = std::collections::HashSet::new();
        protected.insert(("feed-a".to_string(), "book-1".to_string()));

        let max_age = std::time::Duration::from_secs(15 * 24 * 3600);
        let removed = store
            .cleanup_stale_books(&protected, max_age)
            .await
            .unwrap();

        // book-3 should be removed (old + not protected).
        assert_eq!(removed, 1);
        // book-1 should still exist (protected).
        assert!(
            store
                .get_chapter("feed-a", "book-1", "ch-1")
                .await
                .unwrap()
                .is_some()
        );
        // book-2 should still exist (recent).
        assert!(
            store
                .get_chapter("feed-a", "book-2", "ch-1")
                .await
                .unwrap()
                .is_some()
        );
        // book-3 should be gone.
        assert!(
            store
                .get_chapter("feed-b", "book-3", "ch-1")
                .await
                .unwrap()
                .is_none()
        );
    }
}

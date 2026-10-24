//! Cache and maintenance APIs backed directly by the shared database handle.

use super::types::{BridgeError, CacheStats, CleanupResult, CoverData};
use crate::actors::hub_db;
use langhuan::db::Db;
use langhuan::db::maintenance::MaintenanceOutcome;
use langhuan::db::repo::{CacheRepo, CacheStats as RepoCacheStats};

/// Snapshot of database and cache statistics.
pub async fn cache_stats() -> Result<CacheStats, BridgeError> {
    let db = hub_db()?;
    let stats = langhuan::db::maintenance::cache_stats(&db).await?;
    Ok(stats.into())
}

/// Run the full maintenance pass now (stale cleanup, script-history pruning,
/// LRU eviction beyond the 512 MiB cap, vacuum).
///
/// Shelved books and their data are always preserved.
pub async fn cleanup_stale_data() -> Result<CleanupResult, BridgeError> {
    let db = hub_db()?;
    let outcome = langhuan::db::maintenance::run_maintenance(&db, true).await?;
    tracing::info!(
        items_removed = outcome.items_removed,
        bytes_freed = outcome.bytes_freed,
        books_evicted = outcome.books_evicted,
        "manual maintenance complete"
    );
    Ok(outcome.into())
}

/// Clear all cache payloads: chapter content, chapter lists, and covers.
///
/// The bookshelf, reading progress, and bookmarks are untouched; cover state
/// is reset so covers re-download on demand.
pub async fn clear_cache() -> Result<CleanupResult, BridgeError> {
    let db = hub_db()?;
    let (items_removed, bytes_freed) = langhuan::db::maintenance::clear_cache(&db).await?;
    tracing::info!(items_removed, bytes_freed, "cache cleared");
    Ok(CleanupResult {
        skipped: false,
        items_removed,
        bytes_freed,
        books_evicted: 0,
    })
}

/// Read the downloaded cover for a book, if one is stored.
pub async fn get_cover(feed_id: String, book_id: String) -> Result<Option<CoverData>, BridgeError> {
    let db: Db = hub_db()?;
    let cover = db
        .call(move |conn| conn.get_cover_bytes(&feed_id, &book_id))
        .await?;
    Ok(cover.map(|(mime_type, bytes)| CoverData { mime_type, bytes }))
}

/// Map the storage-layer stats onto the bridge type.
impl From<RepoCacheStats> for CacheStats {
    fn from(stats: RepoCacheStats) -> Self {
        CacheStats {
            cache_bytes: stats.cache_bytes,
            db_bytes: stats.db_bytes,
            book_count: stats.book_count,
            cover_count: stats.cover_count,
            chapter_count: stats.chapter_count,
            chapter_list_count: stats.chapter_list_count,
            bookshelf_count: stats.bookshelf_count,
            feed_count: stats.feed_count,
        }
    }
}

/// Map a maintenance outcome onto the bridge type.
impl From<MaintenanceOutcome> for CleanupResult {
    fn from(outcome: MaintenanceOutcome) -> Self {
        CleanupResult {
            skipped: outcome.skipped,
            items_removed: outcome.items_removed,
            bytes_freed: outcome.bytes_freed,
            books_evicted: outcome.books_evicted,
        }
    }
}

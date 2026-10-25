//! Async maintenance orchestration over [`Db`].
//!
//! [`run_maintenance`] is the single entry point used both by the automatic
//! startup pass (throttled to once per 24 h via `meta.last_cleanup_ms`) and
//! by the manual settings action (`force = true`).

use super::Db;
use super::now_ms;
use super::repo::CacheStats;
use crate::error::Result;

/// Cache payloads are capped at 512 MiB; older, unshelved books are evicted
/// beyond that.
pub const MAX_CACHE_BYTES: i64 = 512 * 1024 * 1024;

/// Unshelved cache data older than 15 days is removed.
pub const STALE_MAX_AGE_MS: i64 = 15 * 24 * 60 * 60 * 1000;

/// Script versions kept per feed (newest first, active always kept).
pub const SCRIPT_HISTORY_KEEP: usize = 3;

/// How many books one eviction step deletes.
const EVICT_CHUNK: usize = 32;

/// The automatic startup cleanup runs at most this often.
const CLEANUP_THROTTLE_MS: i64 = 24 * 60 * 60 * 1000;

const META_LAST_CLEANUP: &str = "last_cleanup_ms";

/// Summary of one maintenance run.
#[derive(Debug, Clone, Default)]
pub struct MaintenanceOutcome {
    /// `true` when the run was skipped by the 24 h throttle.
    pub skipped: bool,
    /// Rows deleted (cache rows, stale progress and bookmarks, pruned
    /// script versions).
    pub items_removed: u64,
    /// Cache payload bytes removed.
    pub bytes_freed: i64,
    /// Book rows evicted by the size cap.
    pub books_evicted: u64,
}

/// Run the full maintenance pass.
///
/// 1. Remove stale cache data and user data — progress and bookmarks — for
///    unshelved books (older than 15 days).
/// 2. Prune script histories to [`SCRIPT_HISTORY_KEEP`] versions.
/// 3. Evict least-recently-used unshelved books until under
///    [`MAX_CACHE_BYTES`], in chunks so the database thread stays responsive.
/// 4. `incremental_vacuum` when the pass freed space.
///
/// With `force = false` the pass is skipped when the last one ran less than
/// 24 h ago. The `last_cleanup_ms` timestamp is updated on every run.
pub async fn run_maintenance(db: &Db, force: bool) -> Result<MaintenanceOutcome> {
    let now = now_ms();

    let due = db
        .call(move |conn| {
            Ok(if force {
                true
            } else {
                let last = conn.get_meta_i64(META_LAST_CLEANUP, 0)?;
                now - last >= CLEANUP_THROTTLE_MS
            })
        })
        .await?;
    if !due {
        return Ok(MaintenanceOutcome {
            skipped: true,
            ..MaintenanceOutcome::default()
        });
    }

    let mut outcome = MaintenanceOutcome::default();
    let size_before = db.call(|conn| conn.cache_total_bytes()).await?;

    // 1. Stale cleanup (one transaction).
    let cutoff = now - STALE_MAX_AGE_MS;
    let removed = db.write(move |conn| conn.stale_cleanup(cutoff)).await?;
    outcome.items_removed += removed.items_removed;

    // 2. Script history prune (one transaction).
    let pruned = db
        .write(|conn| conn.prune_all_scripts(SCRIPT_HISTORY_KEEP))
        .await?;
    outcome.items_removed += pruned;

    // 3. LRU eviction, chunked.
    loop {
        let evicted = db
            .call(|conn| conn.evict_oldest_unprotected(MAX_CACHE_BYTES, EVICT_CHUNK))
            .await?;
        outcome.books_evicted += evicted;
        if evicted == 0 {
            break;
        }
    }

    let size_after = db.call(|conn| conn.cache_total_bytes()).await?;
    outcome.bytes_freed = (size_before - size_after).max(0);

    // 4. Give freed pages back to the OS.
    if outcome.bytes_freed > 0 || outcome.items_removed > 0 {
        db.call(|conn| conn.incremental_vacuum()).await?;
    }

    // 5. Record the run (unthrottled writes are fine — one tiny upsert).
    let stamp = now.to_string();
    db.write(move |conn| conn.set_meta(META_LAST_CLEANUP, &stamp))
        .await?;

    if outcome.bytes_freed > 0 || outcome.items_removed > 0 {
        tracing::info!(
            items = outcome.items_removed,
            bytes = outcome.bytes_freed,
            evicted = outcome.books_evicted,
            "database maintenance completed"
        );
    }
    Ok(outcome)
}

/// Clear all cache payloads (settings action). Keeps the bookshelf, progress,
/// bookmarks, and book rows; resets cover state so covers re-download on
/// demand.
///
/// Returns `(rows removed, bytes freed)`.
pub async fn clear_cache(db: &Db) -> Result<(u64, i64)> {
    let size_before = db.call(|conn| conn.cache_total_bytes()).await?;

    let report = db.write(|conn| conn.clear_cache()).await?;

    let size_after = db.call(|conn| conn.cache_total_bytes()).await?;
    db.call(|conn| conn.incremental_vacuum()).await?;

    Ok((report.items_removed, (size_before - size_after).max(0)))
}

/// Cache statistics for the settings screen.
pub async fn cache_stats(db: &Db) -> Result<CacheStats> {
    db.call(|conn| conn.cache_stats()).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::repo::test_support::feed_meta;

    #[tokio::test]
    async fn throttle_skips_within_24h_and_force_overrides() {
        let db = Db::open_in_memory().await.expect("open");
        db.write(|conn| conn.upsert_feed(&feed_meta("f1", "1.0.0"), None, "h", now_ms()))
            .await
            .expect("seed feed");

        // First run executes (no previous run).
        let out = run_maintenance(&db, false).await.expect("run 1");
        assert!(!out.skipped);

        // Second run is throttled.
        let out = run_maintenance(&db, false).await.expect("run 2");
        assert!(out.skipped);

        // Force overrides the throttle.
        let out = run_maintenance(&db, true).await.expect("run 3");
        assert!(!out.skipped);
    }

    /// File-backed (WAL) repro of the incident: shelved books whose
    /// `last_used_at_ms` is older than the stale cutoff must survive a
    /// maintenance pass — only their *unshelved* peers may be dropped.
    #[tokio::test]
    async fn maintenance_preserves_stale_shelved_books_file_backed() {
        use tokio_rusqlite::rusqlite::params;

        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("langhuan.db");
        let db = Db::open(&path).await.expect("open file db");

        let now = now_ms();
        let stale = now - 20 * 24 * 3600 * 1000;

        db.write(move |conn| conn.upsert_feed(&feed_meta("biquge-tw", "1.0.0"), None, "h", now))
            .await
            .expect("seed feed");

        // Four stale shelved books (shelved weeks ago, never opened since)
        // plus one fresh shelved book (recently read).
        for id in ["b1", "b2", "b3", "b4"] {
            db.write({
                let id = id.to_owned();
                move |conn| conn.add_book("biquge-tw", &id, "T", "A", None, None, stale)
            })
            .await
            .expect("add stale shelved book");
        }
        db.write(move |conn| {
            conn.add_book("biquge-tw", "fresh", "T", "A", None, None, now - 3_600_000)
        })
        .await
        .expect("add fresh shelved book");

        // A stale unshelved book — the cleanup's legitimate target.
        db.write(move |conn| conn.ensure_book("biquge-tw", "old-plain", stale))
            .await
            .expect("seed unshelved book");

        // Age the user-era rows and give every old book stale caches
        // (chapter lists, chapter content, covers) — exactly the state the
        // real database was in before the incident.
        db.write(move |conn| {
            conn.conn().execute(
                "UPDATE books SET last_used_at_ms = ?1, info_fetched_at_ms = ?1 \
                 WHERE book_id IN ('b1','b2','b3','b4','old-plain')",
                params![stale],
            )?;
            for id in ["b1", "b2", "b3", "b4", "old-plain"] {
                conn.conn().execute(
                    "INSERT INTO chapter_lists (feed_id, book_id, chapters_json, cached_at_ms) \
                     VALUES ('biquge-tw', ?1, '[]', ?2)",
                    params![id, stale],
                )?;
                conn.conn().execute(
                    "INSERT INTO chapters (feed_id, book_id, chapter_id, paragraphs_json, cached_at_ms) \
                     VALUES ('biquge-tw', ?1, 'c0', '[]', ?2)",
                    params![id, stale],
                )?;
                conn.conn().execute(
                    "INSERT INTO covers (feed_id, book_id, mime, bytes, fetched_at_ms) \
                     VALUES ('biquge-tw', ?1, 'image/jpeg', X'00', ?2)",
                    params![id, stale],
                )?;
            }
            Ok(())
        })
        .await
        .expect("age rows");

        // Sanity: the shelf holds five books before maintenance.
        let items = db
            .call(|conn| conn.shelf_items())
            .await
            .expect("shelf before");
        assert_eq!(items.len(), 5, "seeded shelf must have 5 items");

        // The launch-time maintenance pass.
        let outcome = run_maintenance(&db, true).await.expect("maintenance");
        assert!(!outcome.skipped);
        assert!(
            outcome.items_removed > 0,
            "cleanup must have removed the stale unshelved data (outcome: {outcome:?})"
        );

        let items = db
            .call(|conn| conn.shelf_items())
            .await
            .expect("shelf after");
        assert_eq!(
            items.len(),
            5,
            "stale shelved books must survive maintenance (items: {items:?})"
        );

        // The stale unshelved book must be gone — proving the cleanup ran.
        let plain: i64 = db
            .call(|conn| {
                Ok(conn.conn().query_row(
                    "SELECT COUNT(*) FROM books WHERE book_id = 'old-plain'",
                    [],
                    |r| r.get(0),
                )?)
            })
            .await
            .expect("count old-plain");
        assert_eq!(plain, 0, "stale unshelved book should have been cleaned");

        // And the four stale shelved books must keep their `books` rows.
        let kept: i64 = db
            .call(|conn| {
                Ok(conn.conn().query_row(
                    "SELECT COUNT(*) FROM books WHERE book_id IN ('b1','b2','b3','b4')",
                    [],
                    |r| r.get(0),
                )?)
            })
            .await
            .expect("count shelved books rows");
        assert_eq!(kept, 4, "stale shelved books' rows must survive");
    }

    #[tokio::test]
    async fn maintenance_removes_stale_unshelved_books() {
        let db = Db::open_in_memory().await.expect("open");
        let now = now_ms();
        db.write(move |conn| conn.upsert_feed(&feed_meta("f1", "1.0.0"), None, "h", now))
            .await
            .expect("seed feed");

        let old = now - STALE_MAX_AGE_MS - 1000;
        db.write(move |conn| {
            conn.ensure_book("f1", "old", old)?;
            conn.ensure_book("f1", "kept", old)?;
            conn.add_book("f1", "kept", "Kept", "A", None, None, old)
        })
        .await
        .expect("seed");

        // The stale book is removed by the stale-cleanup step (not by LRU
        // eviction — nothing exceeds the size cap).
        let out = run_maintenance(&db, true).await.expect("run");
        assert!(!out.skipped);
        assert_eq!(out.books_evicted, 0);
        assert!(out.items_removed >= 1);

        let stats = cache_stats(&db).await.expect("stats");
        assert_eq!(stats.book_count, 1); // only the shelved one
        assert_eq!(stats.bookshelf_count, 1);
    }

    #[tokio::test]
    async fn clear_cache_frees_payloads() {
        let db = Db::open_in_memory().await.expect("open");
        let now = now_ms();
        db.write(move |conn| conn.upsert_feed(&feed_meta("f1", "1.0.0"), None, "h", now))
            .await
            .expect("seed feed");

        db.write(move |conn| {
            conn.ensure_book("f1", "b1", now)?;
            conn.add_book("f1", "b1", "T", "A", None, None, now)?;
            conn.set_cover("f1", "b1", "image/png", &[9; 128], now)
        })
        .await
        .expect("seed");

        let before = cache_stats(&db).await.expect("stats");
        assert!(before.cache_bytes >= 128);

        let (removed, freed) = clear_cache(&db).await.expect("clear");
        assert_eq!(removed, 1);
        assert!(freed >= 128);

        let after = cache_stats(&db).await.expect("stats");
        assert_eq!(after.cache_bytes, 0);
        assert_eq!(after.bookshelf_count, 1);
    }
}

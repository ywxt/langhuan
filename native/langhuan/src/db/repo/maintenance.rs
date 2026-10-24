//! Maintenance queries: cache statistics, stale cleanup, LRU eviction, and
//! full cache clears.
//!
//! "Unprotected" books are those without a `bookshelf` row — only their data
//! may be cleaned up or evicted. Shelved books are always preserved.

use tokio_rusqlite::rusqlite::Connection;

use crate::error::Result;

/// Aggregate statistics for the settings screen.
#[derive(Debug, Clone, Default)]
pub struct CacheStats {
    /// Payload bytes stored in the cache tables (covers + chapters + lists).
    pub cache_bytes: i64,
    /// Total size of the database file.
    pub db_bytes: i64,
    pub book_count: i64,
    pub cover_count: i64,
    pub chapter_count: i64,
    pub chapter_list_count: i64,
    pub bookshelf_count: i64,
    pub feed_count: i64,
}

/// Result of a destructive maintenance pass.
#[derive(Debug, Clone, Default)]
pub struct RemovalReport {
    pub items_removed: u64,
}

// ---------------------------------------------------------------------------
// Size accounting
// ---------------------------------------------------------------------------

/// Total payload bytes held by the cache tables (`covers`, `chapters`,
/// `chapter_lists`).
///
/// `length()` on `TEXT` counts characters, so payloads are cast to `BLOB`
/// first to count bytes.
pub fn cache_total_bytes(conn: &Connection) -> Result<i64> {
    let total = conn.query_row(
        "SELECT \
            (SELECT COALESCE(SUM(length(CAST(paragraphs_json AS BLOB))), 0) FROM chapters) + \
            (SELECT COALESCE(SUM(length(CAST(chapters_json AS BLOB))), 0) FROM chapter_lists) + \
            (SELECT COALESCE(SUM(length(bytes)), 0) FROM covers)",
        [],
        |row| row.get(0),
    )?;
    Ok(total)
}

pub fn stats(conn: &Connection) -> Result<CacheStats> {
    let stats = conn.query_row(
        "SELECT \
            (SELECT COALESCE(SUM(length(CAST(paragraphs_json AS BLOB))), 0) FROM chapters) + \
            (SELECT COALESCE(SUM(length(CAST(chapters_json AS BLOB))), 0) FROM chapter_lists) + \
            (SELECT COALESCE(SUM(length(bytes)), 0) FROM covers), \
            (SELECT page_count FROM pragma_page_count) * (SELECT page_size FROM pragma_page_size), \
            (SELECT COUNT(*) FROM books), \
            (SELECT COUNT(*) FROM covers), \
            (SELECT COUNT(*) FROM chapters), \
            (SELECT COUNT(*) FROM chapter_lists), \
            (SELECT COUNT(*) FROM bookshelf), \
            (SELECT COUNT(*) FROM feeds)",
        [],
        |row| {
            Ok(CacheStats {
                cache_bytes: row.get(0)?,
                db_bytes: row.get(1)?,
                book_count: row.get(2)?,
                cover_count: row.get(3)?,
                chapter_count: row.get(4)?,
                chapter_list_count: row.get(5)?,
                bookshelf_count: row.get(6)?,
                feed_count: row.get(7)?,
            })
        },
    )?;
    Ok(stats)
}

// ---------------------------------------------------------------------------
// Stale cleanup (time-driven)
// ---------------------------------------------------------------------------

/// Delete cache rows for unprotected books that have not been used within
/// `max_age_ms`, plus stale reading progress. Bookmarks are user data and are
/// never touched.
///
/// Returns the number of removed rows. `bytes_freed` is measured by the caller
/// via [`cache_total_bytes`] before/after.
pub fn stale_cleanup(conn: &Connection, cutoff_ms: i64) -> Result<RemovalReport> {
    const DELETES: &[&str] = &[
        // Chapter content
        "DELETE FROM chapters WHERE cached_at_ms < ?1 AND NOT EXISTS ( \
             SELECT 1 FROM bookshelf s \
             WHERE s.feed_id = chapters.feed_id AND s.book_id = chapters.book_id)",
        // Chapter lists
        "DELETE FROM chapter_lists WHERE cached_at_ms < ?1 AND NOT EXISTS ( \
             SELECT 1 FROM bookshelf s \
             WHERE s.feed_id = chapter_lists.feed_id AND s.book_id = chapter_lists.book_id)",
        // Covers
        "DELETE FROM covers WHERE fetched_at_ms < ?1 AND NOT EXISTS ( \
             SELECT 1 FROM bookshelf s \
             WHERE s.feed_id = covers.feed_id AND s.book_id = covers.book_id)",
        // Book rows (placeholder and fetched) — cascades anything remaining
        "DELETE FROM books WHERE last_used_at_ms < ?1 AND NOT EXISTS ( \
             SELECT 1 FROM bookshelf s \
             WHERE s.feed_id = books.feed_id AND s.book_id = books.book_id)",
        // Reading progress
        "DELETE FROM reading_progress WHERE updated_at_ms < ?1 AND NOT EXISTS ( \
             SELECT 1 FROM bookshelf s \
             WHERE s.feed_id = reading_progress.feed_id AND s.book_id = reading_progress.book_id)",
    ];

    let mut removed = 0u64;
    for sql in DELETES {
        removed += conn.prepare_cached(sql)?.execute([cutoff_ms])? as u64;
    }
    Ok(RemovalReport {
        items_removed: removed,
    })
}

// ---------------------------------------------------------------------------
// LRU eviction (size-driven)
// ---------------------------------------------------------------------------

/// Evict books to bring the cache under `cap_bytes`.
///
/// Deletes up to `chunk` unprotected books (oldest `last_used_at_ms` first)
/// per call; the caller loops until the cap is met or nothing is left to
/// evict. Chunking keeps each database-thread visit short so normal reads
/// can interleave.
///
/// Returns the number of book rows evicted this call.
pub fn evict_oldest_unprotected(conn: &Connection, cap_bytes: i64, chunk: usize) -> Result<u64> {
    let total = cache_total_bytes(conn)?;
    if total <= cap_bytes {
        return Ok(0);
    }
    let evicted = conn
        .prepare_cached(
            "DELETE FROM books WHERE (feed_id, book_id) IN ( \
                 SELECT b.feed_id, b.book_id FROM books b \
                 WHERE NOT EXISTS ( \
                     SELECT 1 FROM bookshelf s \
                     WHERE s.feed_id = b.feed_id AND s.book_id = b.book_id) \
                 ORDER BY b.last_used_at_ms, b.feed_id, b.book_id \
                 LIMIT ?1)",
        )?
        .execute([chunk as i64])?;
    Ok(evicted as u64)
}

// ---------------------------------------------------------------------------
// Full cache clear (user-triggered)
// ---------------------------------------------------------------------------

/// Clear all cache payloads: chapter content, chapter lists, and covers.
///
/// Bookshelf entries, reading progress, bookmarks, and book rows themselves
/// are kept (shelved books need their `books` rows; the rows are tiny and are
/// removed by stale cleanup once unshelved). `cover_state` is reset so the
/// next access re-downloads covers on demand.
///
/// Returns the number of removed rows.
pub fn clear_cache(conn: &Connection) -> Result<RemovalReport> {
    let mut removed = 0u64;
    removed += conn.prepare_cached("DELETE FROM chapters")?.execute([])? as u64;
    removed += conn.prepare_cached("DELETE FROM chapter_lists")?.execute([])? as u64;
    removed += conn.prepare_cached("DELETE FROM covers")?.execute([])? as u64;
    conn.prepare_cached(
        "UPDATE books SET cover_state = 'none', cover_fetched_at_ms = 0 \
         WHERE cover_state != 'none'",
    )?
    .execute([])?;
    Ok(RemovalReport {
        items_removed: removed,
    })
}

// ---------------------------------------------------------------------------
// Script history
// ---------------------------------------------------------------------------

/// Prune every feed's script history to the newest `keep` versions.
///
/// The active version (`feeds.version`) is always kept — by the install
/// invariant it always has the newest `installed_at_ms`, but it is excluded
/// from deletion explicitly as a safety net.
///
/// Returns the number of history rows pruned.
pub fn prune_all_scripts(conn: &Connection, keep: usize) -> Result<u64> {
    let pruned = conn
        .prepare_cached(
            "DELETE FROM feed_scripts WHERE (feed_id, version) NOT IN ( \
                 SELECT feed_id, version FROM ( \
                     SELECT feed_id, version, \
                            ROW_NUMBER() OVER ( \
                                PARTITION BY feed_id \
                                ORDER BY installed_at_ms DESC, version DESC) AS rn \
                     FROM feed_scripts) WHERE rn <= ?1) \
             AND NOT EXISTS ( \
                 SELECT 1 FROM feeds f \
                 WHERE f.id = feed_scripts.feed_id AND f.version = feed_scripts.version)",
        )?
        .execute([keep as i64])?;
    Ok(pruned as u64)
}

// ---------------------------------------------------------------------------
// Vacuum
// ---------------------------------------------------------------------------

/// Return freed pages to the OS. Only meaningful with
/// `auto_vacuum=INCREMENTAL`; a no-op otherwise. Cheap when nothing is free.
pub fn incremental_vacuum(conn: &Connection) -> Result<()> {
    conn.execute_batch("PRAGMA incremental_vacuum;")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::repo::{bookshelf, cache as cache_repo, feeds as feeds_repo, progress};
    use crate::db::now_ms;
    use crate::feed::FeedMeta;

    fn conn() -> Connection {
        let mut conn = Connection::open_in_memory().expect("open");
        crate::db::schema_for_tests(&mut conn);
        conn
    }

    fn meta(id: &str) -> FeedMeta {
        FeedMeta {
            id: id.to_owned(),
            name: format!("Feed {id}"),
            version: "1.0.0".to_owned(),
            author: None,
            description: None,
            base_url: "https://example.com".to_owned(),
            access_domains: Default::default(),
            schema_version: 1,
        }
    }

    /// Seed a book with `n` cached chapters of `bytes_each` payload bytes.
    fn seed_book(
        conn: &Connection,
        book_id: &str,
        bytes_each: usize,
        n: usize,
        at_ms: i64,
    ) {
        cache_repo::ensure_book(conn, "f1", book_id, at_ms).expect("ensure book");
        let paragraphs = vec![crate::model::Paragraph::Text {
            id: crate::model::ParagraphId::Index(0),
            content: "x".repeat(bytes_each),
        }];
        for i in 0..n {
            cache_repo::set_paragraphs(conn, "f1", book_id, &format!("c{i}"), &paragraphs, at_ms)
                .expect("set paragraphs");
        }
    }

    #[test]
    fn stats_counts_seeded_data() {
        let conn = conn();
        let now = now_ms();
        feeds_repo::upsert_feed(&conn, &meta("f1"), None, "h", now).expect("feed");
        seed_book(&conn, "b1", 100, 3, now);
        cache_repo::set_cover(&conn, "f1", "b1", "image/png", &[7; 50], now).expect("cover");
        bookshelf::add_book(&conn, "f1", "b1", "T", "A", None, None, now).expect("shelf");

        let s = stats(&conn).expect("stats");
        assert_eq!(s.feed_count, 1);
        assert_eq!(s.book_count, 1);
        assert_eq!(s.chapter_count, 3);
        assert_eq!(s.cover_count, 1);
        assert_eq!(s.bookshelf_count, 1);
        // 3 chapters × (100 payload + json overhead) + 50 cover bytes
        assert!(s.cache_bytes > 3 * 100 + 50);
        assert!(s.db_bytes > 0);
    }

    #[test]
    fn stale_cleanup_protects_shelf_and_drops_old() {
        let conn = conn();
        let now = now_ms();
        feeds_repo::upsert_feed(&conn, &meta("f1"), None, "h", now).expect("feed");

        let old = now - 16 * 24 * 3600 * 1000;
        seed_book(&conn, "old-plain", 100, 2, old);
        seed_book(&conn, "old-shelved", 100, 2, old);
        seed_book(&conn, "fresh-plain", 100, 2, now);
        bookshelf::add_book(&conn, "f1", "old-shelved", "T", "A", None, None, now)
            .expect("shelf");
        progress::set(&conn, "f1", "old-plain", "c", "p", old).expect("progress");

        let cutoff = now - 15 * 24 * 3600 * 1000;
        let report = stale_cleanup(&conn, cutoff).expect("cleanup");
        assert!(report.items_removed >= 3); // 2 chapters + book row + progress

        let s = stats(&conn).expect("stats");
        assert_eq!(s.chapter_count, 4); // shelved + fresh survive
        assert_eq!(s.book_count, 2);
        assert!(progress::get(&conn, "f1", "old-plain").expect("progress").is_none());
    }

    #[test]
    fn eviction_oldest_first_and_chunked() {
        let conn = conn();
        let now = now_ms();
        feeds_repo::upsert_feed(&conn, &meta("f1"), None, "h", now).expect("feed");

        seed_book(&conn, "oldest", 100, 1, now - 3000);
        seed_book(&conn, "middle", 100, 1, now - 2000);
        seed_book(&conn, "newest", 100, 1, now - 1000);
        seed_book(&conn, "shelved", 100, 1, now - 5000);
        bookshelf::add_book(&conn, "f1", "shelved", "T", "A", None, None, now)
            .expect("shelf");

        // Cap below the total size → eviction needed.
        let cap = 3 * 100; // roughly one book's payload
        let first = evict_oldest_unprotected(&conn, cap, 1).expect("evict");
        assert_eq!(first, 1); // one chunk of one book

        // The shelved book (oldest by last_used) must never be evicted; the
        // oldest *unprotected* book goes first.
        let s = stats(&conn).expect("stats");
        assert_eq!(s.book_count, 3);
        assert_eq!(
            cache_repo::get_paragraphs(&conn, "f1", "oldest", "c0", now)
                .expect("get")
                .is_none(),
            true
        );
        assert_eq!(
            cache_repo::get_paragraphs(&conn, "f1", "shelved", "c0", now)
                .expect("get")
                .is_some(),
            true
        );
    }

    #[test]
    fn clear_cache_wipes_payloads_keeps_rows_and_resets_state() {
        let conn = conn();
        let now = now_ms();
        feeds_repo::upsert_feed(&conn, &meta("f1"), None, "h", now).expect("feed");
        seed_book(&conn, "b1", 100, 2, now);
        cache_repo::set_cover(&conn, "f1", "b1", "image/png", &[1; 10], now).expect("cover");
        bookshelf::add_book(&conn, "f1", "b1", "T", "A", None, None, now).expect("shelf");
        progress::set(&conn, "f1", "b1", "c1", "p1", now).expect("progress");

        let report = clear_cache(&conn).expect("clear");
        assert_eq!(report.items_removed, 3); // 2 chapters + 1 cover

        let s = stats(&conn).expect("stats");
        assert_eq!(s.chapter_count, 0);
        assert_eq!(s.cover_count, 0);
        assert_eq!(s.book_count, 1); // row kept for the shelf
        assert_eq!(s.bookshelf_count, 1);
        assert!(progress::get(&conn, "f1", "b1").expect("progress").is_some());

        // The cleared cover re-arms: no cover row → hit path spawns a download.
        cache_repo::upsert_fetched_book(
            &conn,
            "f1",
            &crate::model::BookInfo {
                id: "b1".to_owned(),
                title: "T".to_owned(),
                author: "A".to_owned(),
                cover_url: Some("u".to_owned()),
                description: None,
            },
            now,
        )
        .expect("re-fetch");
        let (_, spawn) = cache_repo::get_cached_book_for_hit(&conn, "f1", "b1", now)
            .expect("hit")
            .expect("row");
        assert!(spawn);
    }

    #[test]
    fn prune_all_scripts_keeps_active_and_limit() {
        let conn = conn();
        let now = now_ms();

        // f1: the active version is the newest — plain top-3 pruning.
        let mut m1 = meta("f1");
        m1.version = "1.0.4".to_owned();
        feeds_repo::upsert_feed(&conn, &m1, None, "h", now).expect("feed");
        for (i, v) in ["1.0.1", "1.0.2", "1.0.3", "1.0.4"].iter().enumerate() {
            feeds_repo::upsert_script(&conn, "f1", v, "h", "--s", now + i as i64)
                .expect("script");
        }

        // f2: the active version is artificially the oldest — the safety net
        // must keep it even though it falls outside the top 3.
        let mut m2 = meta("f2");
        m2.version = "1.0.0".to_owned();
        feeds_repo::upsert_feed(&conn, &m2, None, "h", now).expect("feed");
        for (i, v) in ["1.0.0", "1.0.2", "1.0.3", "1.0.4"].iter().enumerate() {
            feeds_repo::upsert_script(&conn, "f2", v, "h", "--s", now + i as i64)
                .expect("script");
        }

        let pruned = prune_all_scripts(&conn, 3).expect("prune");
        assert_eq!(pruned, 1); // f1's 1.0.1; f2 keeps everything (active protected)

        let f1: Vec<String> = feeds_repo::list_scripts(&conn, "f1")
            .expect("list")
            .into_iter()
            .map(|s| s.version)
            .collect();
        assert_eq!(f1, ["1.0.4", "1.0.3", "1.0.2"]);

        let f2: Vec<String> = feeds_repo::list_scripts(&conn, "f2")
            .expect("list")
            .into_iter()
            .map(|s| s.version)
            .collect();
        assert!(f2.contains(&"1.0.0".to_owned()), "active kept: {f2:?}");
        assert_eq!(f2.len(), 4);
    }
}

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

/// Maintenance operations, as methods on [`Connection`].
pub trait MaintenanceRepo {
    /// Total payload bytes held by the cache tables (`covers`, `chapters`,
    /// `chapter_lists`).
    ///
    /// `length()` on `TEXT` counts characters, so payloads are cast to
    /// `BLOB` first to count bytes.
    fn cache_total_bytes(&self) -> Result<i64>;

    fn cache_stats(&self) -> Result<CacheStats>;

    /// Delete cache rows and user data for unprotected books that have not
    /// been used within `cutoff_ms`: chapter content, chapter lists,
    /// covers, book rows, reading progress, and bookmarks.
    ///
    /// Returns the number of removed rows. `bytes_freed` is measured by the
    /// caller via [`MaintenanceRepo::cache_total_bytes`] before/after.
    fn stale_cleanup(&self, cutoff_ms: i64) -> Result<RemovalReport>;

    /// Evict books to bring the cache under `cap_bytes`.
    ///
    /// Deletes up to `chunk` unprotected books (oldest `last_used_at_ms`
    /// first) per call; the caller loops until the cap is met or nothing is
    /// left to evict. Chunking keeps each database-thread visit short so
    /// normal reads can interleave.
    ///
    /// Returns the number of book rows evicted this call.
    fn evict_oldest_unprotected(&self, cap_bytes: i64, chunk: usize) -> Result<u64>;

    /// Clear all cache payloads: chapter content, chapter lists, and covers.
    ///
    /// Bookshelf entries, reading progress, bookmarks, and book rows
    /// themselves are kept (shelved books need their `books` rows; the rows
    /// are tiny and are removed by stale cleanup once unshelved).
    /// `cover_state` is reset so the next access re-downloads covers on
    /// demand.
    ///
    /// Returns the number of removed rows.
    fn clear_cache(&self) -> Result<RemovalReport>;

    /// Prune every feed's script history to the newest `keep` versions.
    ///
    /// The active version (`feeds.version`) is always kept — by the install
    /// invariant it always has the newest `installed_at_ms`, but it is
    /// excluded from deletion explicitly as a safety net.
    ///
    /// Returns the number of history rows pruned.
    fn prune_all_scripts(&self, keep: usize) -> Result<u64>;

    /// Return freed pages to the OS. Only meaningful with
    /// `auto_vacuum=INCREMENTAL`; a no-op otherwise. Cheap when nothing is
    /// free.
    fn incremental_vacuum(&self) -> Result<()>;
}

impl MaintenanceRepo for Connection {
    fn cache_total_bytes(&self) -> Result<i64> {
        let total = self.query_row(
            "SELECT \
                (SELECT COALESCE(SUM(length(CAST(paragraphs_json AS BLOB))), 0) FROM chapters) + \
                (SELECT COALESCE(SUM(length(CAST(chapters_json AS BLOB))), 0) FROM chapter_lists) + \
                (SELECT COALESCE(SUM(length(bytes)), 0) FROM covers)",
            [],
            |row| row.get(0),
        )?;
        Ok(total)
    }

    fn cache_stats(&self) -> Result<CacheStats> {
        let stats = self.query_row(
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

    fn stale_cleanup(&self, cutoff_ms: i64) -> Result<RemovalReport> {
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
            // Bookmarks — an unshelved book's data goes with the book
            "DELETE FROM bookmarks WHERE created_at_ms < ?1 AND NOT EXISTS ( \
                 SELECT 1 FROM bookshelf s \
                 WHERE s.feed_id = bookmarks.feed_id AND s.book_id = bookmarks.book_id)",
        ];

        let mut removed = 0u64;
        for sql in DELETES {
            removed += self.prepare_cached(sql)?.execute([cutoff_ms])? as u64;
        }
        Ok(RemovalReport {
            items_removed: removed,
        })
    }

    fn evict_oldest_unprotected(&self, cap_bytes: i64, chunk: usize) -> Result<u64> {
        let total = self.cache_total_bytes()?;
        if total <= cap_bytes {
            return Ok(0);
        }
        let evicted = self
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

    fn clear_cache(&self) -> Result<RemovalReport> {
        let mut removed = 0u64;
        removed += self.prepare_cached("DELETE FROM chapters")?.execute([])? as u64;
        removed += self
            .prepare_cached("DELETE FROM chapter_lists")?
            .execute([])? as u64;
        removed += self.prepare_cached("DELETE FROM covers")?.execute([])? as u64;
        self.prepare_cached(
            "UPDATE books SET cover_state = 'none', cover_fetched_at_ms = 0 \
             WHERE cover_state != 'none'",
        )?
        .execute([])?;
        Ok(RemovalReport {
            items_removed: removed,
        })
    }

    fn prune_all_scripts(&self, keep: usize) -> Result<u64> {
        let pruned = self
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

    fn incremental_vacuum(&self) -> Result<()> {
        self.execute_batch("PRAGMA incremental_vacuum;")?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::now_ms;
    use crate::db::repo::test_support::{TestDb, feed_meta};
    use crate::db::repo::{
        BookmarkRow, BookmarksRepo, BookshelfRepo, CacheRepo, FeedsRepo, ProgressRepo,
    };

    /// Seed a book with `n` cached chapters of `bytes_each` payload bytes.
    fn seed_book(conn: &Connection, book_id: &str, bytes_each: usize, n: usize, at_ms: i64) {
        conn.ensure_book("f1", book_id, at_ms).expect("ensure book");
        let paragraphs = vec![crate::model::Paragraph::Text {
            id: crate::model::ParagraphId::Index(0),
            content: "x".repeat(bytes_each),
        }];
        for i in 0..n {
            conn.set_paragraphs("f1", book_id, &format!("c{i}"), &paragraphs, at_ms)
                .expect("set paragraphs");
        }
    }

    #[test]
    fn stats_counts_seeded_data() {
        let db = TestDb::new();
        db.seed_feed("f1");
        let conn = db.conn();
        let now = now_ms();
        seed_book(conn, "b1", 100, 3, now);
        conn.set_cover("f1", "b1", "image/png", &[7; 50], now)
            .expect("cover");
        conn.add_book("f1", "b1", "T", "A", None, None, now)
            .expect("shelf");

        let s = conn.cache_stats().expect("stats");
        assert_eq!(s.feed_count, 1);
        assert_eq!(s.book_count, 1);
        assert_eq!(s.chapter_count, 3);
        assert_eq!(s.cover_count, 1);
        assert_eq!(s.bookshelf_count, 1);
        // 3 chapters × (100 payload + json overhead) + 50 cover bytes
        assert!(s.cache_bytes > 3 * 100 + 50);
        assert!(s.db_bytes > 0);
    }

    /// Seed a bookmark for book `book_id`, created at `at_ms`.
    fn bookmark(conn: &Connection, id: &str, book_id: &str, at_ms: i64) {
        conn.add_bookmark(&BookmarkRow {
            id: id.to_owned(),
            feed_id: "f1".to_owned(),
            book_id: book_id.to_owned(),
            chapter_id: "c".to_owned(),
            paragraph_id: "p".to_owned(),
            paragraph_name: "n".to_owned(),
            paragraph_preview: "x".to_owned(),
            label: "l".to_owned(),
            created_at_ms: at_ms,
        })
        .expect("bookmark");
    }

    #[test]
    fn stale_cleanup_protects_shelf_and_drops_old() {
        let db = TestDb::new();
        db.seed_feed("f1");
        let conn = db.conn();
        let now = now_ms();

        let old = now - 16 * 24 * 3600 * 1000;
        seed_book(conn, "old-plain", 100, 2, old);
        seed_book(conn, "old-shelved", 100, 2, old);
        seed_book(conn, "fresh-plain", 100, 2, now);
        conn.add_book("f1", "old-shelved", "T", "A", None, None, now)
            .expect("shelf");
        conn.set_progress("f1", "old-plain", "c", "p", 0, old)
            .expect("progress");
        bookmark(conn, "k1", "old-plain", old);
        bookmark(conn, "k2", "old-shelved", old);

        let cutoff = now - 15 * 24 * 3600 * 1000;
        let report = conn.stale_cleanup(cutoff).expect("cleanup");
        // 2 chapters + book row + progress + bookmark
        assert!(report.items_removed >= 4);

        let s = conn.cache_stats().expect("stats");
        assert_eq!(s.chapter_count, 4); // shelved + fresh survive
        assert_eq!(s.book_count, 2);
        assert!(
            conn.get_progress("f1", "old-plain")
                .expect("progress")
                .is_none()
        );
        // Stale unshelved bookmarks go; shelved ones stay.
        assert!(
            conn.list_bookmarks("f1", "old-plain")
                .expect("bookmarks")
                .is_empty()
        );
        assert_eq!(
            conn.list_bookmarks("f1", "old-shelved")
                .expect("bookmarks")
                .len(),
            1
        );
    }

    #[test]
    fn eviction_oldest_first_and_chunked() {
        let db = TestDb::new();
        db.seed_feed("f1");
        let conn = db.conn();
        let now = now_ms();

        seed_book(conn, "oldest", 100, 1, now - 3000);
        seed_book(conn, "middle", 100, 1, now - 2000);
        seed_book(conn, "newest", 100, 1, now - 1000);
        seed_book(conn, "shelved", 100, 1, now - 5000);
        conn.add_book("f1", "shelved", "T", "A", None, None, now)
            .expect("shelf");

        // Cap below the total size → eviction needed.
        let cap = 3 * 100; // roughly one book's payload
        let first = conn.evict_oldest_unprotected(cap, 1).expect("evict");
        assert_eq!(first, 1); // one chunk of one book

        // The shelved book (oldest by last_used) must never be evicted; the
        // oldest *unprotected* book goes first.
        let s = conn.cache_stats().expect("stats");
        assert_eq!(s.book_count, 3);
        assert!(
            conn.get_paragraphs("f1", "oldest", "c0", now)
                .expect("get")
                .is_none()
        );
        assert!(
            conn.get_paragraphs("f1", "shelved", "c0", now)
                .expect("get")
                .is_some()
        );
    }

    #[test]
    fn clear_cache_wipes_payloads_keeps_rows_and_resets_state() {
        let db = TestDb::new();
        db.seed_feed("f1");
        let conn = db.conn();
        let now = now_ms();
        seed_book(conn, "b1", 100, 2, now);
        conn.set_cover("f1", "b1", "image/png", &[1; 10], now)
            .expect("cover");
        conn.add_book("f1", "b1", "T", "A", None, None, now)
            .expect("shelf");
        conn.set_progress("f1", "b1", "c1", "p1", 0, now)
            .expect("progress");

        let report = conn.clear_cache().expect("clear");
        assert_eq!(report.items_removed, 3); // 2 chapters + 1 cover

        let s = conn.cache_stats().expect("stats");
        assert_eq!(s.chapter_count, 0);
        assert_eq!(s.cover_count, 0);
        assert_eq!(s.book_count, 1); // row kept for the shelf
        assert_eq!(s.bookshelf_count, 1);
        assert!(conn.get_progress("f1", "b1").expect("progress").is_some());

        // The cleared cover re-arms: state 'none' + a URL → the claim is due.
        conn.upsert_fetched_book(
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
        assert!(conn.claim_cover_download("f1", "b1", now).expect("claim"));
    }

    #[test]
    fn prune_all_scripts_keeps_active_and_limit() {
        let db = TestDb::new();
        db.seed_feed("f1");
        let conn = db.conn();
        let now = now_ms();

        // f1: the active version is the newest — plain top-3 pruning.
        let m1 = feed_meta("f1", "1.0.4");
        conn.upsert_feed(&m1, None, "h", now).expect("feed");
        for (i, v) in ["1.0.1", "1.0.2", "1.0.3", "1.0.4"].iter().enumerate() {
            conn.upsert_script("f1", v, "h", "--s", now + i as i64)
                .expect("script");
        }

        // f2: the active version is artificially the oldest — the safety net
        // must keep it even though it falls outside the top 3.
        let m2 = feed_meta("f2", "1.0.0");
        conn.upsert_feed(&m2, None, "h", now).expect("feed");
        for (i, v) in ["1.0.0", "1.0.2", "1.0.3", "1.0.4"].iter().enumerate() {
            conn.upsert_script("f2", v, "h", "--s", now + i as i64)
                .expect("script");
        }

        let pruned = conn.prune_all_scripts(3).expect("prune");
        assert_eq!(pruned, 1); // f1's 1.0.1; f2 keeps everything (active protected)

        let f1: Vec<String> = conn
            .list_scripts("f1")
            .expect("list")
            .into_iter()
            .map(|s| s.version)
            .collect();
        assert_eq!(f1, ["1.0.4", "1.0.3", "1.0.2"]);

        let f2: Vec<String> = conn
            .list_scripts("f2")
            .expect("list")
            .into_iter()
            .map(|s| s.version)
            .collect();
        assert!(f2.contains(&"1.0.0".to_owned()), "active kept: {f2:?}");
        assert_eq!(f2.len(), 4);
    }
}

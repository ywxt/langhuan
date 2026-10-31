//! `reading_progress` — one row per (feed, book).

use super::Repo;

use crate::error::Result;

#[derive(Debug, Clone)]
pub struct ProgressRow {
    pub feed_id: String,
    pub book_id: String,
    pub chapter_id: String,
    pub paragraph_id: String,
    /// Character offset of the page-leading character within the paragraph
    /// (horizontal mode); 0 means the paragraph's start.
    pub paragraph_char_offset: u32,
    pub updated_at_ms: i64,
}

impl Repo<'_> {
    pub fn get_progress(&self, feed_id: &str, book_id: &str) -> Result<Option<ProgressRow>> {
        super::maybe_row(
            self.conn,
            "SELECT feed_id, book_id, chapter_id, paragraph_id, paragraph_char_offset, updated_at_ms \
             FROM reading_progress WHERE feed_id = ?1 AND book_id = ?2",
            &[&feed_id, &book_id],
            |row| {
                Ok(ProgressRow {
                    feed_id: row.get(0)?,
                    book_id: row.get(1)?,
                    chapter_id: row.get(2)?,
                    paragraph_id: row.get(3)?,
                    paragraph_char_offset: row.get::<_, i64>(4)? as u32,
                    updated_at_ms: row.get(5)?,
                })
            },
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn set_progress(
        &self,
        feed_id: &str,
        book_id: &str,
        chapter_id: &str,
        paragraph_id: &str,
        paragraph_char_offset: u32,
        now_ms: i64,
    ) -> Result<()> {
        self.conn.prepare_cached(
            "INSERT INTO reading_progress (feed_id, book_id, chapter_id, paragraph_id, paragraph_char_offset, updated_at_ms) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6) \
             ON CONFLICT(feed_id, book_id) DO UPDATE SET \
                 chapter_id = excluded.chapter_id, \
                 paragraph_id = excluded.paragraph_id, \
                 paragraph_char_offset = excluded.paragraph_char_offset, \
                 updated_at_ms = excluded.updated_at_ms",
        )?
        .execute(tokio_rusqlite::params![
            feed_id,
            book_id,
            chapter_id,
            paragraph_id,
            paragraph_char_offset,
            now_ms
        ])?;
        Ok(())
    }

    /// Delete progress rows older than `cutoff_ms` for books that are not on
    /// the bookshelf. Returns the number of rows removed.
    pub fn remove_stale_progress(&self, cutoff_ms: i64) -> Result<u64> {
        let removed = self.conn
            .prepare_cached(
                "DELETE FROM reading_progress WHERE updated_at_ms < ?1 \
                 AND NOT EXISTS ( \
                     SELECT 1 FROM bookshelf s \
                     WHERE s.feed_id = reading_progress.feed_id AND s.book_id = reading_progress.book_id)",
            )?
            .execute([cutoff_ms])?;
        Ok(removed as u64)
    }
}

#[cfg(test)]
mod tests {
    use crate::db::repo::test_support::TestDb;

    #[test]
    fn set_get_overwrites() {
        let db = TestDb::new();
        db.seed_feed("f1");
        let conn = db.repo();
        conn.set_progress("f1", "b1", "c1", "p1", 0, 100).unwrap();
        conn.set_progress("f1", "b1", "c2", "p9", 240, 200).unwrap();

        let row = conn.get_progress("f1", "b1").unwrap().expect("row");
        assert_eq!(row.chapter_id, "c2");
        assert_eq!(row.paragraph_id, "p9");
        assert_eq!(row.paragraph_char_offset, 240);
        assert_eq!(row.updated_at_ms, 200);
        assert!(conn.get_progress("f1", "b2").unwrap().is_none());
    }

    #[test]
    fn char_offset_defaults_to_zero_for_old_rows() {
        let db = TestDb::new();
        db.seed_feed("f1");
        db.conn()
            .execute_batch(
                "INSERT INTO reading_progress (feed_id, book_id, chapter_id, paragraph_id, updated_at_ms) \
                 VALUES ('f1', 'b1', 'c1', 'p1', 100);",
            )
            .unwrap();

        let row = db.repo().get_progress("f1", "b1").unwrap().expect("row");
        assert_eq!(row.paragraph_char_offset, 0);
    }

    #[test]
    fn stale_removal_respects_shelf() {
        let db = TestDb::new();
        db.seed_feed("f1");
        db.seed_shelf_item("f1", "b1");
        let conn = db.repo();
        conn.set_progress("f1", "b1", "c", "p", 0, 100).unwrap(); // old but protected
        conn.set_progress("f1", "b2", "c", "p", 0, 100).unwrap(); // old, unprotected
        conn.set_progress("f1", "b3", "c", "p", 0, 10_000).unwrap(); // fresh
        // b3 needs no `books` row: `reading_progress` references feeds only.

        let removed = conn.remove_stale_progress(1000).unwrap();
        assert_eq!(removed, 1);
        assert!(conn.get_progress("f1", "b1").unwrap().is_some());
        assert!(conn.get_progress("f1", "b2").unwrap().is_none());
        assert!(conn.get_progress("f1", "b3").unwrap().is_some());
    }
}

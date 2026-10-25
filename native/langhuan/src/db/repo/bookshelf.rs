//! `bookshelf` — shelved books, joined with their cached metadata.

use std::collections::HashSet;

use super::Repo;

use crate::error::Result;

/// A bookshelf list item: the shelf row joined with the book's metadata.
#[derive(Debug, Clone)]
pub struct ShelfItem {
    pub feed_id: String,
    pub book_id: String,
    pub title: String,
    pub author: String,
    pub description: Option<String>,
    pub cover_url: Option<String>,
    pub added_at_ms: i64,
    pub last_seen_chapters: i64,
    pub progress_current_chapter: Option<i64>,
    pub progress_total_chapters: Option<i64>,
}

impl Repo<'_> {
    /// Add a book to the shelf, seeding a placeholder `books` row (from the
    /// search-result snapshot) when none exists yet.
    ///
    /// Runs the two writes atomically; the FK on `bookshelf` guarantees a
    /// matching `books` row. Returns `false` when the book was already
    /// shelved.
    ///
    /// Whether a cover download should run is *not* the repo's business:
    /// callers spawn one whenever the snapshot carries a `cover_url` and
    /// [`Repo::claim_cover_download`] decides whether it is due.
    #[allow(clippy::too_many_arguments)]
    pub fn add_book(
        &self,
        feed_id: &str,
        book_id: &str,
        title: &str,
        author: &str,
        description: Option<&str>,
        cover_url: Option<&str>,
        now_ms: i64,
    ) -> Result<bool> {
        self.upsert_snapshot(
            feed_id,
            book_id,
            title,
            author,
            description,
            cover_url,
            now_ms,
        )?;

        let inserted = self.conn
            .prepare_cached(
                "INSERT OR IGNORE INTO bookshelf (feed_id, book_id, added_at_ms) VALUES (?1, ?2, ?3)",
            )?
            .execute(tokio_rusqlite::params![feed_id, book_id, now_ms])?;
        Ok(inserted > 0)
    }

    /// Remove a book from the shelf and delete all of its data.
    ///
    /// Runs atomically in the caller's transaction: the `bookshelf` entry,
    /// the `books` row (schema-cascading chapters, chapter lists, and
    /// covers), reading progress, and bookmarks. Returns `false` when it
    /// was not shelved.
    pub fn remove_book(&self, feed_id: &str, book_id: &str) -> Result<bool> {
        let removed = self
            .conn
            .prepare_cached("DELETE FROM bookshelf WHERE feed_id = ?1 AND book_id = ?2")?
            .execute([feed_id, book_id])?;
        if removed == 0 {
            return Ok(false);
        }
        // Deleting the `books` row schema-cascades chapters, chapter lists,
        // and covers; progress and bookmarks only cascade from `feeds`.
        self.conn
            .prepare_cached("DELETE FROM books WHERE feed_id = ?1 AND book_id = ?2")?
            .execute([feed_id, book_id])?;
        self.conn
            .prepare_cached("DELETE FROM reading_progress WHERE feed_id = ?1 AND book_id = ?2")?
            .execute([feed_id, book_id])?;
        self.conn
            .prepare_cached("DELETE FROM bookmarks WHERE feed_id = ?1 AND book_id = ?2")?
            .execute([feed_id, book_id])?;
        Ok(true)
    }

    /// List the shelf, newest first, joined with cached metadata.
    ///
    /// A shelved book always has a `books` row (enforced by the FK), so the
    /// inner join can never drop entries.
    pub fn shelf_items(&self) -> Result<Vec<ShelfItem>> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT s.feed_id, s.book_id, b.title, b.author, b.description, b.cover_url, s.added_at_ms, s.last_seen_chapters, rp.chapter_id, cl.chapters_json \
             FROM bookshelf s \
             JOIN books b ON b.feed_id = s.feed_id AND b.book_id = s.book_id \
             LEFT JOIN reading_progress rp ON rp.feed_id = s.feed_id AND rp.book_id = s.book_id \
             LEFT JOIN chapter_lists cl ON cl.feed_id = s.feed_id AND cl.book_id = s.book_id \
             ORDER BY s.added_at_ms DESC, s.feed_id, s.book_id",
        )?;
        let items = stmt
            .query_map([], |row| {
                let chapter_id = row.get::<_, Option<String>>(8)?;
                let chapters_json = row.get::<_, Option<String>>(9)?;
                let (progress_current_chapter, progress_total_chapters) =
                    chapter_progress(chapter_id.as_deref(), chapters_json.as_deref());
                Ok(ShelfItem {
                    feed_id: row.get(0)?,
                    book_id: row.get(1)?,
                    title: row.get(2)?,
                    author: row.get(3)?,
                    description: row.get(4)?,
                    cover_url: row.get(5)?,
                    added_at_ms: row.get(6)?,
                    last_seen_chapters: row.get(7)?,
                    progress_current_chapter,
                    progress_total_chapters,
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(items)
    }

    /// Record the chapter count the user has last seen for a shelved book
    /// (detail page or reader list load). No-op when the book is not shelved.
    pub fn set_last_seen_chapters(&self, feed_id: &str, book_id: &str, count: i64) -> Result<()> {
        self.conn
            .prepare_cached(
                "UPDATE bookshelf SET last_seen_chapters = ?3 WHERE feed_id = ?1 AND book_id = ?2",
            )?
            .execute(tokio_rusqlite::params![feed_id, book_id, count])?;
        Ok(())
    }

    /// Is this book currently shelved?
    pub fn is_shelved(&self, feed_id: &str, book_id: &str) -> Result<bool> {
        let found = self
            .conn
            .prepare_cached(
                "SELECT EXISTS(SELECT 1 FROM bookshelf WHERE feed_id = ?1 AND book_id = ?2)",
            )?
            .query_row([feed_id, book_id], |row| row.get::<_, i64>(0))?;
        Ok(found == 1)
    }

    /// All shelved `(feed_id, book_id)` pairs — the set of books protected
    /// from cache eviction and stale cleanup.
    pub fn protected_pairs(&self) -> Result<HashSet<(String, String)>> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT feed_id, book_id FROM bookshelf")?;
        let pairs = stmt
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?
            .collect::<std::result::Result<HashSet<_>, _>>()?;
        Ok(pairs)
    }
}

fn chapter_progress(
    current_chapter_id: Option<&str>,
    chapters_json: Option<&str>,
) -> (Option<i64>, Option<i64>) {
    let (Some(current_chapter_id), Some(chapters_json)) = (current_chapter_id, chapters_json)
    else {
        return (None, None);
    };
    let Ok(chapters) = serde_json::from_str::<Vec<crate::model::ChapterInfo>>(chapters_json) else {
        return (None, None);
    };
    let Some(index) = chapters
        .iter()
        .position(|chapter| chapter.id == current_chapter_id)
    else {
        return (None, None);
    };
    (Some(index as i64 + 1), Some(chapters.len() as i64))
}

#[cfg(test)]
mod tests {
    use crate::db::now_ms;
    use crate::db::repo::test_support::TestDb;

    #[test]
    fn add_is_idempotent_and_lists_newest_first() {
        let db = TestDb::new();
        db.seed_feed("f1");
        let conn = db.repo();
        let now = now_ms();
        assert!(conn
            .add_book("f1", "b1", "One", "A", None, Some("u1"), now)
            .unwrap());
        assert!(!conn
            .add_book("f1", "b1", "One", "A", None, Some("u1"), now + 5)
            .unwrap());
        assert!(conn
            .add_book("f1", "b2", "Two", "B", None, None, now + 10)
            .unwrap());

        let items = conn.shelf_items().unwrap();
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].book_id, "b2"); // newest first
        assert_eq!(items[0].title, "Two");

        assert!(conn.is_shelved("f1", "b1").unwrap());
        let protected = conn.protected_pairs().unwrap();
        assert!(protected.contains(&("f1".to_owned(), "b1".to_owned())));
    }

    #[test]
    fn last_seen_chapters_defaults_and_updates() {
        let db = TestDb::new();
        db.seed_feed("f1");
        let conn = db.repo();
        assert!(conn
            .add_book("f1", "b1", "One", "A", None, None, now_ms())
            .unwrap());

        // Freshly shelved books have never been seen (-1).
        assert_eq!(conn.shelf_items().unwrap()[0].last_seen_chapters, -1);

        // Marking a seen count persists through the list query.
        conn.set_last_seen_chapters("f1", "b1", 42).unwrap();
        assert_eq!(conn.shelf_items().unwrap()[0].last_seen_chapters, 42);

        // Marking an unshelved book is a no-op (no row, no error).
        conn.set_last_seen_chapters("f1", "missing", 7).unwrap();
        assert_eq!(conn.shelf_items().unwrap().len(), 1);

        // Removing the book drops the seen count with the row.
        assert!(conn.remove_book("f1", "b1").unwrap());
        assert!(conn.shelf_items().unwrap().is_empty());
    }

    #[test]
    fn list_includes_cached_chapter_progress() {
        let db = TestDb::new();
        db.seed_feed("f1");
        db.seed_shelf_item("f1", "b1");
        let conn = db.repo();
        conn.conn()
            .execute_batch(
                r#"
                INSERT INTO chapter_lists VALUES (
                    'f1', 'b1',
                    '[{"id":"c1","title":"One"},{"id":"c2","title":"Two"},{"id":"c3","title":"Three"}]',
                    1
                );
                INSERT INTO reading_progress (
                    feed_id, book_id, chapter_id, paragraph_id, updated_at_ms
                ) VALUES ('f1', 'b1', 'c2', 'p1', 1);
                "#,
            )
            .expect("seed progress");

        let item = &conn.shelf_items().unwrap()[0];
        assert_eq!(item.progress_current_chapter, Some(2));
        assert_eq!(item.progress_total_chapters, Some(3));
    }

    #[test]
    fn remove_then_list() {
        let db = TestDb::new();
        db.seed_feed("f1");
        let conn = db.repo();
        let now = now_ms();
        conn.add_book("f1", "b1", "One", "A", None, None, now)
            .unwrap();
        assert!(conn.remove_book("f1", "b1").unwrap());
        assert!(!conn.remove_book("f1", "b1").unwrap());
        assert!(conn.shelf_items().unwrap().is_empty());
    }

    #[test]
    fn remove_deletes_book_data() {
        let db = TestDb::new();
        db.seed_feed("f1");
        let conn = db.repo();
        let now = now_ms();
        conn.add_book("f1", "b1", "One", "A", None, None, now)
            .unwrap();
        conn.conn().execute_batch(
            "INSERT INTO chapters VALUES ('f1', 'b1', 'c1', '[]', 1); \
             INSERT INTO chapter_lists VALUES ('f1', 'b1', '[]', 1); \
             INSERT INTO covers VALUES ('f1', 'b1', 'image/png', x'00', 1); \
             INSERT INTO reading_progress (feed_id, book_id, chapter_id, paragraph_id, updated_at_ms) VALUES ('f1', 'b1', 'c1', 'p1', 1); \
             INSERT INTO bookmarks VALUES ('k1', 'f1', 'b1', 'c1', 'p1', 'n', 'x', 'l', 1);",
        )
        .expect("seed book data");

        assert!(conn.remove_book("f1", "b1").unwrap());

        let count = |sql: &str| {
            conn.conn()
                .query_row(sql, [], |row| row.get::<_, i64>(0))
                .unwrap()
        };
        assert_eq!(count("SELECT COUNT(*) FROM bookshelf"), 0);
        assert_eq!(count("SELECT COUNT(*) FROM books"), 0);
        assert_eq!(count("SELECT COUNT(*) FROM chapters"), 0);
        assert_eq!(count("SELECT COUNT(*) FROM chapter_lists"), 0);
        assert_eq!(count("SELECT COUNT(*) FROM covers"), 0);
        assert_eq!(count("SELECT COUNT(*) FROM reading_progress"), 0);
        assert_eq!(count("SELECT COUNT(*) FROM bookmarks"), 0);
    }
}

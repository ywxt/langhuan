//! `bookshelf` — shelved books, joined with their cached metadata.

use std::collections::HashSet;

use tokio_rusqlite::rusqlite::Connection;

use crate::error::Result;

use super::cache::CacheRepo;

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
}

/// Bookshelf operations, as methods on [`Connection`].
pub trait BookshelfRepo {
    /// Add a book to the shelf, seeding a placeholder `books` row (from the
    /// search-result snapshot) when none exists yet.
    ///
    /// Runs the two writes atomically; the FK on `bookshelf` guarantees a
    /// matching `books` row. Returns `false` when the book was already
    /// shelved.
    ///
    /// Whether a cover download should run is *not* the repo's business:
    /// callers spawn one whenever the snapshot carries a `cover_url` and
    /// [`CacheRepo::claim_cover_download`] decides whether it is due.
    #[allow(clippy::too_many_arguments)]
    fn add_book(
        &self,
        feed_id: &str,
        book_id: &str,
        title: &str,
        author: &str,
        description: Option<&str>,
        cover_url: Option<&str>,
        now_ms: i64,
    ) -> Result<bool>;

    /// Remove a book from the shelf and delete all of its data.
    ///
    /// Runs atomically in the caller's transaction: the `bookshelf` entry,
    /// the `books` row (schema-cascading chapters, chapter lists, and
    /// covers), reading progress, and bookmarks. Returns `false` when it
    /// was not shelved.
    fn remove_book(&self, feed_id: &str, book_id: &str) -> Result<bool>;

    /// List the shelf, newest first, joined with cached metadata.
    ///
    /// A shelved book always has a `books` row (enforced by the FK), so the
    /// inner join can never drop entries.
    fn shelf_items(&self) -> Result<Vec<ShelfItem>>;

    /// Is this book currently shelved?
    fn is_shelved(&self, feed_id: &str, book_id: &str) -> Result<bool>;

    /// All shelved `(feed_id, book_id)` pairs — the set of books protected
    /// from cache eviction and stale cleanup.
    fn protected_pairs(&self) -> Result<HashSet<(String, String)>>;
}

impl BookshelfRepo for Connection {
    fn add_book(
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

        let inserted = self
            .prepare_cached(
                "INSERT OR IGNORE INTO bookshelf (feed_id, book_id, added_at_ms) VALUES (?1, ?2, ?3)",
            )?
            .execute(tokio_rusqlite::params![feed_id, book_id, now_ms])?;
        Ok(inserted > 0)
    }

    fn remove_book(&self, feed_id: &str, book_id: &str) -> Result<bool> {
        let removed = self
            .prepare_cached("DELETE FROM bookshelf WHERE feed_id = ?1 AND book_id = ?2")?
            .execute([feed_id, book_id])?;
        if removed == 0 {
            return Ok(false);
        }
        // Deleting the `books` row schema-cascades chapters, chapter lists,
        // and covers; progress and bookmarks only cascade from `feeds`.
        self.prepare_cached("DELETE FROM books WHERE feed_id = ?1 AND book_id = ?2")?
            .execute([feed_id, book_id])?;
        self.prepare_cached(
            "DELETE FROM reading_progress WHERE feed_id = ?1 AND book_id = ?2",
        )?
        .execute([feed_id, book_id])?;
        self.prepare_cached("DELETE FROM bookmarks WHERE feed_id = ?1 AND book_id = ?2")?
            .execute([feed_id, book_id])?;
        Ok(true)
    }

    fn shelf_items(&self) -> Result<Vec<ShelfItem>> {
        let mut stmt = self.prepare_cached(
            "SELECT s.feed_id, s.book_id, b.title, b.author, b.description, b.cover_url, s.added_at_ms \
             FROM bookshelf s \
             JOIN books b ON b.feed_id = s.feed_id AND b.book_id = s.book_id \
             ORDER BY s.added_at_ms DESC, s.feed_id, s.book_id",
        )?;
        let items = stmt
            .query_map([], |row| {
                Ok(ShelfItem {
                    feed_id: row.get(0)?,
                    book_id: row.get(1)?,
                    title: row.get(2)?,
                    author: row.get(3)?,
                    description: row.get(4)?,
                    cover_url: row.get(5)?,
                    added_at_ms: row.get(6)?,
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(items)
    }

    fn is_shelved(&self, feed_id: &str, book_id: &str) -> Result<bool> {
        let found = self
            .prepare_cached(
                "SELECT EXISTS(SELECT 1 FROM bookshelf WHERE feed_id = ?1 AND book_id = ?2)",
            )?
            .query_row([feed_id, book_id], |row| row.get::<_, i64>(0))?;
        Ok(found == 1)
    }

    fn protected_pairs(&self) -> Result<HashSet<(String, String)>> {
        let mut stmt = self.prepare_cached("SELECT feed_id, book_id FROM bookshelf")?;
        let pairs = stmt
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?
            .collect::<std::result::Result<HashSet<_>, _>>()?;
        Ok(pairs)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::now_ms;

    const SCHEMA: &str = "\
        CREATE TABLE feeds (id TEXT PRIMARY KEY, name TEXT NOT NULL, version TEXT NOT NULL, author TEXT, source_url TEXT, content_hash TEXT NOT NULL, installed_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL) WITHOUT ROWID; \
        CREATE TABLE books (feed_id TEXT NOT NULL, book_id TEXT NOT NULL, title TEXT NOT NULL, author TEXT NOT NULL, description TEXT, cover_url TEXT, cover_state TEXT NOT NULL DEFAULT 'none' CHECK (cover_state IN ('none','pending','downloaded','failed')), cover_fetched_at_ms INTEGER NOT NULL DEFAULT 0, info_fetched_at_ms INTEGER NOT NULL DEFAULT 0, last_used_at_ms INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (feed_id, book_id), FOREIGN KEY (feed_id) REFERENCES feeds(id) ON DELETE CASCADE) WITHOUT ROWID; \
        CREATE TABLE covers (feed_id TEXT NOT NULL, book_id TEXT NOT NULL, mime TEXT NOT NULL, bytes BLOB NOT NULL, fetched_at_ms INTEGER NOT NULL, PRIMARY KEY (feed_id, book_id), FOREIGN KEY (feed_id, book_id) REFERENCES books(feed_id, book_id) ON DELETE CASCADE) WITHOUT ROWID; \
        CREATE TABLE bookshelf (feed_id TEXT NOT NULL, book_id TEXT NOT NULL, added_at_ms INTEGER NOT NULL, PRIMARY KEY (feed_id, book_id), FOREIGN KEY (feed_id, book_id) REFERENCES books(feed_id, book_id) ON DELETE CASCADE) WITHOUT ROWID; \
        CREATE TABLE chapter_lists (feed_id TEXT NOT NULL, book_id TEXT NOT NULL, chapters_json TEXT NOT NULL, cached_at_ms INTEGER NOT NULL, PRIMARY KEY (feed_id, book_id), FOREIGN KEY (feed_id, book_id) REFERENCES books(feed_id, book_id) ON DELETE CASCADE) WITHOUT ROWID; \
        CREATE TABLE chapters (feed_id TEXT NOT NULL, book_id TEXT NOT NULL, chapter_id TEXT NOT NULL, paragraphs_json TEXT NOT NULL, cached_at_ms INTEGER NOT NULL, PRIMARY KEY (feed_id, book_id, chapter_id), FOREIGN KEY (feed_id, book_id) REFERENCES books(feed_id, book_id) ON DELETE CASCADE) WITHOUT ROWID; \
        CREATE TABLE reading_progress (feed_id TEXT NOT NULL, book_id TEXT NOT NULL, chapter_id TEXT NOT NULL, paragraph_id TEXT NOT NULL, updated_at_ms INTEGER NOT NULL, PRIMARY KEY (feed_id, book_id), FOREIGN KEY (feed_id) REFERENCES feeds(id) ON DELETE CASCADE) WITHOUT ROWID; \
        CREATE TABLE bookmarks (id TEXT PRIMARY KEY, feed_id TEXT NOT NULL, book_id TEXT NOT NULL, chapter_id TEXT NOT NULL, paragraph_id TEXT NOT NULL, paragraph_name TEXT NOT NULL, paragraph_preview TEXT NOT NULL, label TEXT NOT NULL, created_at_ms INTEGER NOT NULL, FOREIGN KEY (feed_id) REFERENCES feeds(id) ON DELETE CASCADE) WITHOUT ROWID;";

    fn conn() -> Connection {
        let conn = Connection::open_in_memory().expect("open");
        conn.execute_batch(SCHEMA).expect("schema");
        conn.execute_batch(
            "INSERT INTO feeds VALUES ('f1', 'Feed', '1.0', NULL, NULL, 'h', 1, 1);",
        )
        .expect("seed");
        conn
    }

    #[test]
    fn add_is_idempotent_and_lists_newest_first() {
        let conn = conn();
        let now = now_ms();
        assert!(
            conn.add_book("f1", "b1", "One", "A", None, Some("u1"), now)
                .unwrap()
        );
        assert!(
            !conn
                .add_book("f1", "b1", "One", "A", None, Some("u1"), now + 5)
                .unwrap()
        );
        assert!(
            conn.add_book("f1", "b2", "Two", "B", None, None, now + 10)
                .unwrap()
        );

        let items = conn.shelf_items().unwrap();
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].book_id, "b2"); // newest first
        assert_eq!(items[0].title, "Two");

        assert!(conn.is_shelved("f1", "b1").unwrap());
        let protected = conn.protected_pairs().unwrap();
        assert!(protected.contains(&("f1".to_owned(), "b1".to_owned())));
    }

    #[test]
    fn remove_then_list() {
        let conn = conn();
        let now = now_ms();
        conn.add_book("f1", "b1", "One", "A", None, None, now)
            .unwrap();
        assert!(conn.remove_book("f1", "b1").unwrap());
        assert!(!conn.remove_book("f1", "b1").unwrap());
        assert!(conn.shelf_items().unwrap().is_empty());
    }

    #[test]
    fn remove_deletes_book_data() {
        let conn = conn();
        let now = now_ms();
        conn.add_book("f1", "b1", "One", "A", None, None, now)
            .unwrap();
        conn.execute_batch(
            "INSERT INTO chapters VALUES ('f1', 'b1', 'c1', '[]', 1); \
             INSERT INTO chapter_lists VALUES ('f1', 'b1', '[]', 1); \
             INSERT INTO covers VALUES ('f1', 'b1', 'image/png', x'00', 1); \
             INSERT INTO reading_progress VALUES ('f1', 'b1', 'c1', 'p1', 1); \
             INSERT INTO bookmarks VALUES ('k1', 'f1', 'b1', 'c1', 'p1', 'n', 'x', 'l', 1);",
        )
        .expect("seed book data");

        assert!(conn.remove_book("f1", "b1").unwrap());

        let count = |sql: &str| conn.query_row(sql, [], |row| row.get::<_, i64>(0)).unwrap();
        assert_eq!(count("SELECT COUNT(*) FROM bookshelf"), 0);
        assert_eq!(count("SELECT COUNT(*) FROM books"), 0);
        assert_eq!(count("SELECT COUNT(*) FROM chapters"), 0);
        assert_eq!(count("SELECT COUNT(*) FROM chapter_lists"), 0);
        assert_eq!(count("SELECT COUNT(*) FROM covers"), 0);
        assert_eq!(count("SELECT COUNT(*) FROM reading_progress"), 0);
        assert_eq!(count("SELECT COUNT(*) FROM bookmarks"), 0);
    }
}

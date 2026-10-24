//! `bookshelf` — shelved books, joined with their cached metadata.

use std::collections::HashSet;

use tokio_rusqlite::rusqlite::Connection;

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
    pub has_cover: bool,
    pub added_at_ms: i64,
}

/// Outcome of [`add_book`].
pub struct AddOutcome {
    /// `false` when the book was already shelved.
    pub added: bool,
    /// Whether a cover download should be spawned for this book.
    pub spawn_cover: bool,
}

/// Add a book to the shelf, seeding a placeholder `books` row (from the
/// search-result snapshot) when none exists yet.
///
/// Runs the two writes atomically; the FK on `bookshelf` guarantees a
/// matching `books` row.
pub fn add_book(
    conn: &Connection,
    feed_id: &str,
    book_id: &str,
    title: &str,
    author: &str,
    description: Option<&str>,
    cover_url: Option<&str>,
    now_ms: i64,
) -> Result<AddOutcome> {
    let spawn_cover = super::cache::upsert_snapshot(
        conn,
        feed_id,
        book_id,
        title,
        author,
        description,
        cover_url,
        now_ms,
    )?;

    let inserted = conn
        .prepare_cached(
            "INSERT OR IGNORE INTO bookshelf (feed_id, book_id, added_at_ms) VALUES (?1, ?2, ?3)",
        )?
        .execute(tokio_rusqlite::params![feed_id, book_id, now_ms])?;
    Ok(AddOutcome {
        added: inserted > 0,
        spawn_cover,
    })
}

/// Remove a book from the shelf (its `books` row and caches stay until they
/// go stale or get evicted). Returns `false` when it was not shelved.
pub fn remove_book(conn: &Connection, feed_id: &str, book_id: &str) -> Result<bool> {
    let deleted = conn
        .prepare_cached("DELETE FROM bookshelf WHERE feed_id = ?1 AND book_id = ?2")?
        .execute([feed_id, book_id])?;
    Ok(deleted > 0)
}

/// List the shelf, newest first, joined with cached metadata.
///
/// A shelved book always has a `books` row (enforced by the FK), so the
/// inner join can never drop entries.
pub fn list(conn: &Connection) -> Result<Vec<ShelfItem>> {
    let mut stmt = conn.prepare_cached(
        "SELECT s.feed_id, s.book_id, b.title, b.author, b.description, b.cover_url, \
                (c.feed_id IS NOT NULL) AS has_cover, s.added_at_ms \
         FROM bookshelf s \
         JOIN books b ON b.feed_id = s.feed_id AND b.book_id = s.book_id \
         LEFT JOIN covers c ON c.feed_id = s.feed_id AND c.book_id = s.book_id \
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
                has_cover: row.get::<_, i64>(6)? == 1,
                added_at_ms: row.get(7)?,
            })
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    Ok(items)
}

/// Is this book currently shelved?
pub fn contains(conn: &Connection, feed_id: &str, book_id: &str) -> Result<bool> {
    let found = conn
        .prepare_cached(
            "SELECT EXISTS(SELECT 1 FROM bookshelf WHERE feed_id = ?1 AND book_id = ?2)",
        )?
        .query_row([feed_id, book_id], |row| row.get::<_, i64>(0))?;
    Ok(found == 1)
}

/// All shelved `(feed_id, book_id)` pairs — the set of books protected from
/// cache eviction and stale cleanup.
pub fn protected_pairs(conn: &Connection) -> Result<HashSet<(String, String)>> {
    let mut stmt =
        conn.prepare_cached("SELECT feed_id, book_id FROM bookshelf")?;
    let pairs = stmt
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?
        .collect::<std::result::Result<HashSet<_>, _>>()?;
    Ok(pairs)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::now_ms;

    const SCHEMA: &str = "\
        CREATE TABLE feeds (id TEXT PRIMARY KEY, name TEXT NOT NULL, version TEXT NOT NULL, author TEXT, source_url TEXT, content_hash TEXT NOT NULL, installed_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL) WITHOUT ROWID; \
        CREATE TABLE books (feed_id TEXT NOT NULL, book_id TEXT NOT NULL, title TEXT NOT NULL, author TEXT NOT NULL, description TEXT, cover_url TEXT, cover_state TEXT NOT NULL DEFAULT 'none' CHECK (cover_state IN ('none','pending','downloaded','failed')), cover_fetched_at_ms INTEGER NOT NULL DEFAULT 0, info_fetched_at_ms INTEGER NOT NULL DEFAULT 0, last_used_at_ms INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (feed_id, book_id), FOREIGN KEY (feed_id) REFERENCES feeds(id) ON DELETE CASCADE) WITHOUT ROWID; \
        CREATE TABLE covers (feed_id TEXT NOT NULL, book_id TEXT NOT NULL, mime TEXT NOT NULL, bytes BLOB NOT NULL, fetched_at_ms INTEGER NOT NULL, PRIMARY KEY (feed_id, book_id), FOREIGN KEY (feed_id, book_id) REFERENCES books(feed_id, book_id) ON DELETE CASCADE) WITHOUT ROWID; \
        CREATE TABLE bookshelf (feed_id TEXT NOT NULL, book_id TEXT NOT NULL, added_at_ms INTEGER NOT NULL, PRIMARY KEY (feed_id, book_id), FOREIGN KEY (feed_id, book_id) REFERENCES books(feed_id, book_id) ON DELETE CASCADE) WITHOUT ROWID;";

    fn conn() -> Connection {
        let conn = Connection::open_in_memory().expect("open");
        conn.execute_batch(SCHEMA).expect("schema");
        conn.execute_batch("INSERT INTO feeds VALUES ('f1', 'Feed', '1.0', NULL, NULL, 'h', 1, 1);")
            .expect("seed");
        conn
    }

    #[test]
    fn add_is_idempotent_and_lists_newest_first() {
        let conn = conn();
        let now = now_ms();
        let out = add_book(&conn, "f1", "b1", "One", "A", None, Some("u1"), now).unwrap();
        assert!(out.added);
        assert!(out.spawn_cover); // cover URL present on a fresh row
        let out = add_book(&conn, "f1", "b1", "One", "A", None, Some("u1"), now + 5).unwrap();
        assert!(!out.added);
        assert!(add_book(&conn, "f1", "b2", "Two", "B", None, None, now + 10)
            .unwrap()
            .added);

        let items = list(&conn).unwrap();
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].book_id, "b2"); // newest first
        assert_eq!(items[0].title, "Two");
        assert!(!items[0].has_cover);

        assert!(contains(&conn, "f1", "b1").unwrap());
        let protected = protected_pairs(&conn).unwrap();
        assert!(protected.contains(&("f1".to_owned(), "b1".to_owned())));
    }

    #[test]
    fn remove_then_list() {
        let conn = conn();
        let now = now_ms();
        add_book(&conn, "f1", "b1", "One", "A", None, None, now).unwrap();
        assert!(remove_book(&conn, "f1", "b1").unwrap());
        assert!(!remove_book(&conn, "f1", "b1").unwrap());
        assert!(list(&conn).unwrap().is_empty());
    }
}

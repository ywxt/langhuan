//! `reading_progress` — one row per (feed, book).

use tokio_rusqlite::rusqlite::Connection;

use crate::error::Result;

#[derive(Debug, Clone)]
pub struct ProgressRow {
    pub feed_id: String,
    pub book_id: String,
    pub chapter_id: String,
    pub paragraph_id: String,
    pub updated_at_ms: i64,
}

pub fn get(conn: &Connection, feed_id: &str, book_id: &str) -> Result<Option<ProgressRow>> {
    super::maybe_row(
        conn,
        "SELECT feed_id, book_id, chapter_id, paragraph_id, updated_at_ms \
         FROM reading_progress WHERE feed_id = ?1 AND book_id = ?2",
        &[&feed_id, &book_id],
        |row| {
            Ok(ProgressRow {
                feed_id: row.get(0)?,
                book_id: row.get(1)?,
                chapter_id: row.get(2)?,
                paragraph_id: row.get(3)?,
                updated_at_ms: row.get(4)?,
            })
        },
    )
}

pub fn set(
    conn: &Connection,
    feed_id: &str,
    book_id: &str,
    chapter_id: &str,
    paragraph_id: &str,
    now_ms: i64,
) -> Result<()> {
    conn.prepare_cached(
        "INSERT INTO reading_progress (feed_id, book_id, chapter_id, paragraph_id, updated_at_ms) \
         VALUES (?1, ?2, ?3, ?4, ?5) \
         ON CONFLICT(feed_id, book_id) DO UPDATE SET \
             chapter_id = excluded.chapter_id, \
             paragraph_id = excluded.paragraph_id, \
             updated_at_ms = excluded.updated_at_ms",
    )?
    .execute(tokio_rusqlite::params![
        feed_id,
        book_id,
        chapter_id,
        paragraph_id,
        now_ms
    ])?;
    Ok(())
}

/// Delete progress rows older than `cutoff_ms` for books that are not on the
/// bookshelf. Returns the number of rows removed.
pub fn remove_stale(conn: &Connection, cutoff_ms: i64) -> Result<u64> {
    let removed = conn
        .prepare_cached(
            "DELETE FROM reading_progress WHERE updated_at_ms < ?1 \
             AND NOT EXISTS ( \
                 SELECT 1 FROM bookshelf s \
                 WHERE s.feed_id = reading_progress.feed_id AND s.book_id = reading_progress.book_id)",
        )?
        .execute([cutoff_ms])?;
    Ok(removed as u64)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SCHEMA: &str = "\
        CREATE TABLE feeds (id TEXT PRIMARY KEY, name TEXT NOT NULL, version TEXT NOT NULL, author TEXT, source_url TEXT, content_hash TEXT NOT NULL, installed_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL) WITHOUT ROWID; \
        CREATE TABLE books (feed_id TEXT NOT NULL, book_id TEXT NOT NULL, title TEXT NOT NULL, author TEXT NOT NULL, description TEXT, cover_url TEXT, cover_state TEXT NOT NULL DEFAULT 'none', cover_fetched_at_ms INTEGER NOT NULL DEFAULT 0, info_fetched_at_ms INTEGER NOT NULL DEFAULT 0, last_used_at_ms INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (feed_id, book_id), FOREIGN KEY (feed_id) REFERENCES feeds(id) ON DELETE CASCADE) WITHOUT ROWID; \
        CREATE TABLE bookshelf (feed_id TEXT NOT NULL, book_id TEXT NOT NULL, added_at_ms INTEGER NOT NULL, PRIMARY KEY (feed_id, book_id), FOREIGN KEY (feed_id, book_id) REFERENCES books(feed_id, book_id) ON DELETE CASCADE) WITHOUT ROWID; \
        CREATE TABLE reading_progress (feed_id TEXT NOT NULL, book_id TEXT NOT NULL, chapter_id TEXT NOT NULL, paragraph_id TEXT NOT NULL, updated_at_ms INTEGER NOT NULL, PRIMARY KEY (feed_id, book_id), FOREIGN KEY (feed_id) REFERENCES feeds(id) ON DELETE CASCADE) WITHOUT ROWID;";

    fn conn() -> Connection {
        let conn = Connection::open_in_memory().expect("open");
        conn.execute_batch(SCHEMA).expect("schema");
        conn.execute_batch("INSERT INTO feeds VALUES ('f1', 'Feed', '1.0', NULL, NULL, 'h', 1, 1); \
                            INSERT INTO books (feed_id, book_id, title, author) VALUES ('f1', 'b1', 'T', 'A'), ('f1', 'b2', 'T2', 'A');")
            .expect("seed");
        conn
    }

    #[test]
    fn set_get_overwrites() {
        let conn = conn();
        set(&conn, "f1", "b1", "c1", "p1", 100).unwrap();
        set(&conn, "f1", "b1", "c2", "p9", 200).unwrap();

        let row = get(&conn, "f1", "b1").unwrap().expect("row");
        assert_eq!(row.chapter_id, "c2");
        assert_eq!(row.paragraph_id, "p9");
        assert_eq!(row.updated_at_ms, 200);
        assert!(get(&conn, "f1", "b2").unwrap().is_none());
    }

    #[test]
    fn stale_removal_respects_shelf() {
        let conn = conn();
        conn.execute_batch("INSERT INTO bookshelf VALUES ('f1', 'b1', 1);")
            .unwrap();
        set(&conn, "f1", "b1", "c", "p", 100).unwrap(); // old but protected
        set(&conn, "f1", "b2", "c", "p", 100).unwrap(); // old, unprotected
        set(&conn, "f1", "b3", "c", "p", 10_000).unwrap(); // fresh
        // b3 has no books row — set() would violate nothing (FK is on feeds),
        // but b3 was never inserted into books above; insert for realism:
        // (feeds FK only, so this passes.)

        let removed = remove_stale(&conn, 1000).unwrap();
        assert_eq!(removed, 1);
        assert!(get(&conn, "f1", "b1").unwrap().is_some());
        assert!(get(&conn, "f1", "b2").unwrap().is_none());
        assert!(get(&conn, "f1", "b3").unwrap().is_some());
    }
}

//! Schema migrations, tracked with `PRAGMA user_version`.
//!
//! Each entry bumps `user_version` to its number and runs its SQL inside a
//! transaction. Migrations are append-only: never edit an existing entry,
//! always add a new one.

use tokio_rusqlite::rusqlite::Connection;

use crate::error::Result;

/// A single migration: the `user_version` it sets, and the SQL it executes.
struct Migration {
    version: i64,
    sql: &'static str,
}

const MIGRATIONS: &[Migration] = &[Migration {
    version: 1,
    sql: r#"
        -- Feed registry -----------------------------------------------------
        CREATE TABLE feeds (
            id              TEXT PRIMARY KEY,
            name            TEXT NOT NULL,
            version         TEXT NOT NULL,
            author          TEXT,
            source_url      TEXT,
            content_hash    TEXT NOT NULL,
            installed_at_ms INTEGER NOT NULL,
            updated_at_ms   INTEGER NOT NULL
        ) WITHOUT ROWID;

        -- Script history. `feeds.version` points at the active row.
        -- Old versions are kept (bounded) so an upgrade can be undone by
        -- re-pointing `feeds.version` at a previous row.
        CREATE TABLE feed_scripts (
            feed_id         TEXT NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
            version         TEXT NOT NULL,
            content_hash    TEXT NOT NULL,
            script          TEXT NOT NULL,
            installed_at_ms INTEGER NOT NULL,
            PRIMARY KEY (feed_id, version)
        ) WITHOUT ROWID;

        -- Book cache --------------------------------------------------------
        -- One row per (feed, book) that has ever been opened or shelved.
        -- `info_fetched_at_ms = 0` marks a placeholder row seeded from a
        -- search-result snapshot (never fetched from the source).
        CREATE TABLE books (
            feed_id             TEXT NOT NULL,
            book_id             TEXT NOT NULL,
            title               TEXT NOT NULL,
            author              TEXT NOT NULL,
            description         TEXT,
            cover_url           TEXT,
            cover_state         TEXT NOT NULL DEFAULT 'none'
                                CHECK (cover_state IN ('none','pending','downloaded','failed')),
            cover_fetched_at_ms INTEGER NOT NULL DEFAULT 0,
            info_fetched_at_ms  INTEGER NOT NULL DEFAULT 0,
            last_used_at_ms     INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (feed_id, book_id),
            FOREIGN KEY (feed_id) REFERENCES feeds(id) ON DELETE CASCADE
        ) WITHOUT ROWID;

        CREATE TABLE covers (
            feed_id      TEXT NOT NULL,
            book_id      TEXT NOT NULL,
            mime         TEXT NOT NULL,
            bytes        BLOB NOT NULL,
            fetched_at_ms INTEGER NOT NULL,
            PRIMARY KEY (feed_id, book_id),
            FOREIGN KEY (feed_id, book_id)
                REFERENCES books(feed_id, book_id) ON DELETE CASCADE
        ) WITHOUT ROWID;

        -- User data ---------------------------------------------------------
        -- The bookshelf references books (FK CASCADE): a shelved book's row
        -- and cover survive cache eviction because eviction only targets
        -- books with no bookshelf row.
        CREATE TABLE bookshelf (
            feed_id     TEXT NOT NULL,
            book_id     TEXT NOT NULL,
            added_at_ms INTEGER NOT NULL,
            PRIMARY KEY (feed_id, book_id),
            FOREIGN KEY (feed_id, book_id)
                REFERENCES books(feed_id, book_id) ON DELETE CASCADE
        ) WITHOUT ROWID;

        -- Reading progress and bookmarks reference feeds only (not books):
        -- they are user data and must survive cache eviction of the book row.
        CREATE TABLE reading_progress (
            feed_id       TEXT NOT NULL,
            book_id       TEXT NOT NULL,
            chapter_id    TEXT NOT NULL,
            paragraph_id  TEXT NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            PRIMARY KEY (feed_id, book_id),
            FOREIGN KEY (feed_id) REFERENCES feeds(id) ON DELETE CASCADE
        ) WITHOUT ROWID;

        CREATE TABLE bookmarks (
            id                 TEXT PRIMARY KEY,
            feed_id            TEXT NOT NULL,
            book_id            TEXT NOT NULL,
            chapter_id         TEXT NOT NULL,
            paragraph_id       TEXT NOT NULL,
            paragraph_name     TEXT NOT NULL DEFAULT '',
            paragraph_preview  TEXT NOT NULL DEFAULT '',
            label              TEXT NOT NULL DEFAULT '',
            created_at_ms      INTEGER NOT NULL,
            FOREIGN KEY (feed_id) REFERENCES feeds(id) ON DELETE CASCADE
        ) WITHOUT ROWID;
        CREATE INDEX idx_bookmarks_book ON bookmarks(feed_id, book_id, created_at_ms);

        CREATE TABLE auth (
            feed_id      TEXT PRIMARY KEY,
            cookies_json TEXT NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            FOREIGN KEY (feed_id) REFERENCES feeds(id) ON DELETE CASCADE
        ) WITHOUT ROWID;

        -- Content cache -----------------------------------------------------
        CREATE TABLE chapter_lists (
            feed_id       TEXT NOT NULL,
            book_id       TEXT NOT NULL,
            chapters_json TEXT NOT NULL,
            cached_at_ms  INTEGER NOT NULL,
            PRIMARY KEY (feed_id, book_id),
            FOREIGN KEY (feed_id, book_id)
                REFERENCES books(feed_id, book_id) ON DELETE CASCADE
        ) WITHOUT ROWID;

        CREATE TABLE chapters (
            feed_id         TEXT NOT NULL,
            book_id         TEXT NOT NULL,
            chapter_id      TEXT NOT NULL,
            paragraphs_json TEXT NOT NULL,
            cached_at_ms    INTEGER NOT NULL,
            PRIMARY KEY (feed_id, book_id, chapter_id),
            FOREIGN KEY (feed_id, book_id)
                REFERENCES books(feed_id, book_id) ON DELETE CASCADE
        ) WITHOUT ROWID;

        -- Key-value metadata (e.g. last_cleanup_ms) --------------------------
        CREATE TABLE meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        ) WITHOUT ROWID;
    "#,
}];

/// The schema version this build understands (the last migration's version).
pub(crate) const CURRENT_VERSION: i64 = 1;

/// Apply all pending migrations in order.
pub(crate) fn migrate(conn: &mut Connection) -> Result<()> {
    let current: i64 = conn.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    for migration in MIGRATIONS {
        if migration.version <= current {
            continue;
        }
        let tx = conn.transaction()?;
        tx.execute_batch(migration.sql)?;
        tx.execute_batch(&format!("PRAGMA user_version = {};", migration.version))?;
        tx.commit()?;
        tracing::info!(
            version = migration.version,
            "database schema migration applied"
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versions_are_strictly_increasing() {
        for pair in MIGRATIONS.windows(2) {
            assert!(
                pair[0].version < pair[1].version,
                "migrations must be ordered"
            );
        }
        assert_eq!(
            MIGRATIONS.last().expect("at least one").version,
            CURRENT_VERSION
        );
    }
}

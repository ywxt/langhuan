//! Shared scaffold for repository tests — the same shape as rustc-perf's
//! database tests: one type owning an isolated database, with fixture
//! helpers on it, so each test states only the behavior it exercises.
//!
//! The connection carries the **real production schema** (applied through
//! the actual migrations), not a hand-rolled copy of the DDL — tests cannot
//! drift behind schema changes, which the per-module copies had.

use tokio_rusqlite::rusqlite::Connection;

use crate::db::now_ms;
use crate::feed::FeedMeta;

use super::Repo;

/// An isolated in-memory database with the real production schema.
pub struct TestDb {
    conn: Connection,
}

impl TestDb {
    pub fn new() -> Self {
        let mut conn = Connection::open_in_memory().expect("open in-memory connection");
        crate::db::schema_for_tests(&mut conn);
        Self { conn }
    }

    /// The repository view over the test connection.
    pub fn repo(&self) -> Repo<'_> {
        Repo::new(&self.conn)
    }

    /// The raw connection (schema-level assertions).
    pub fn conn(&self) -> &Connection {
        &self.conn
    }

    /// Register a feed (no script history — most tests only need the row).
    pub fn seed_feed(&self, id: &str) {
        self.repo()
            .upsert_feed(&feed_meta(id, "1.0.0"), None, "hash", now_ms())
            .expect("seed feed");
    }

    /// Shelve a book; also seeds its placeholder `books` row. The feed must
    /// already exist (the `books` foreign key requires it).
    pub fn seed_shelf_item(&self, feed_id: &str, book_id: &str) {
        self.repo()
            .add_book(feed_id, book_id, "Title", "Author", None, None, now_ms())
            .expect("seed shelf item");
    }
}

impl Default for TestDb {
    fn default() -> Self {
        Self::new()
    }
}

/// A [`FeedMeta`] fixture with sensible defaults.
pub fn feed_meta(id: &str, version: &str) -> FeedMeta {
    FeedMeta {
        id: id.to_owned(),
        name: format!("Feed {id}"),
        version: version.to_owned(),
        author: None,
        description: None,
        base_url: "https://example.com".to_owned(),
        access_domains: Default::default(),
        schema_version: 1,
    }
}

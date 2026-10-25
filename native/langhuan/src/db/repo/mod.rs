//! Hand-written repositories over the SQLite schema.
//!
//! Every module adds inherent methods to [`Repo`], a wrapper over the
//! SQLite connection, so repo functions read as repository methods:
//!
//! ```
//! # use langhuan::db::repo::Repo;
//! fn example(repo: &Repo<'_>) -> langhuan::error::Result<()> {
//!     repo.set_meta("key", "value")
//! }
//! ```
//!
//! Every method is synchronous and takes `&self`, so any group of them can
//! run inside one `Db::write` transaction by calling them sequentially in
//! the closure. SQL is written as `const` strings; there is no dynamic query
//! construction anywhere.
//!
//! Method names are unique across the modules, so the wrapper carries one
//! flat, greppable API surface and any subset of modules can be used
//! together without ambiguity.

pub mod auth;
pub mod bookmarks;
pub mod bookshelf;
pub mod cache;
pub mod feeds;
pub mod maintenance;
pub mod meta;
pub mod progress;
#[cfg(test)]
pub(crate) mod test_support;

pub use bookmarks::BookmarkRow;
pub use bookshelf::ShelfItem;
pub use cache::{BookRow, CoverState};
pub use feeds::{FeedRow, ScriptRow};
pub use maintenance::{CacheStats, RemovalReport};
pub use progress::ProgressRow;

use tokio_rusqlite::rusqlite::Connection;

use crate::error::{Error, Result};

/// The repository API over one SQLite connection.
///
/// [`Db::write`](crate::db::Db::write) and
/// [`Db::call`](crate::db::Db::call) hand closures a `&Repo`, so callers
/// see the typed API instead of the raw connection;
/// [`conn`](Self::conn) is the escape hatch for the rare raw-SQL need
/// (schema introspection, PRAGMAs).
pub struct Repo<'a> {
    conn: &'a Connection,
}

impl<'a> Repo<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// The underlying connection (PRAGMAs, schema introspection, raw SQL).
    pub fn conn(&self) -> &Connection {
        self.conn
    }

    /// Write a standalone snapshot of the whole database to `path`
    /// (`VACUUM INTO`): a single compacted file with the WAL folded in,
    /// consistent as of this call. `VACUUM` cannot run inside a
    /// transaction, so this must be invoked through
    /// [`Db::call`](crate::db::Db::call), not `Db::write`.
    ///
    /// Fails when `path` already exists (the caller owns the target).
    pub fn vacuum_into(&self, path: &str) -> Result<()> {
        self.conn.execute("VACUUM INTO ?1", [path])?;
        Ok(())
    }
}

/// Deserialize a JSON payload stored in the database.
///
/// Corrupt payloads surface as `Error::Persistence(Database)` so callers can
/// clear the broken row and fall back to a fresh fetch.
pub(super) fn decode_json<T: serde::de::DeserializeOwned>(what: &str, json: &str) -> Result<T> {
    serde_json::from_str(json).map_err(|e| Error::database(format!("corrupt {what} payload: {e}")))
}

/// Run a `SELECT` that maps zero-or-one row into `Option<T>`.
pub(super) fn maybe_row<T>(
    conn: &Connection,
    sql: &str,
    params: &[&dyn tokio_rusqlite::rusqlite::ToSql],
    map: impl FnOnce(&tokio_rusqlite::rusqlite::Row<'_>) -> tokio_rusqlite::rusqlite::Result<T>,
) -> Result<Option<T>> {
    let mut stmt = conn.prepare_cached(sql)?;
    match stmt.query_row(params, map) {
        Ok(value) => Ok(Some(value)),
        Err(tokio_rusqlite::rusqlite::Error::QueryReturnedNoRows) => Ok(None),
        Err(e) => Err(e.into()),
    }
}

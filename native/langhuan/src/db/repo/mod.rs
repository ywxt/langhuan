//! Hand-written repositories over the SQLite schema.
//!
//! Each module defines a trait (e.g. [`cache::CacheRepo`]) implemented for
//! [`Connection`], so repo functions read as connection methods:
//!
//! ```
//! # use langhuan::db::repo::MetaRepo;
//! # use tokio_rusqlite::rusqlite::Connection;
//! fn example(conn: &Connection) -> langhuan::error::Result<()> {
//!     conn.set_meta("key", "value")
//! }
//! ```
//!
//! Every method is synchronous and takes `&self`, so any group of them can
//! run inside one `Db::write` transaction by calling them sequentially in
//! the closure. SQL is written as `const` strings; there is no dynamic query
//! construction anywhere.
//!
//! Method names are unique across the repo traits, so any subset of traits
//! can be imported together without ambiguity.

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

pub use auth::AuthRepo;
pub use bookmarks::{BookmarkRow, BookmarksRepo};
pub use bookshelf::{BookshelfRepo, ShelfItem};
pub use cache::{BookRow, CacheRepo, CoverState};
pub use feeds::{FeedRow, FeedsRepo, ScriptRow};
pub use maintenance::{CacheStats, MaintenanceRepo, RemovalReport};
pub use meta::MetaRepo;
pub use progress::{ProgressRepo, ProgressRow};

use tokio_rusqlite::rusqlite::Connection;

use crate::error::{Error, Result};

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

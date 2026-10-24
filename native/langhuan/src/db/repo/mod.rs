//! Hand-written repositories over the SQLite schema.
//!
//! Every function is synchronous and takes `&Connection`, so any group of
//! them can run inside one `Db::write` transaction by calling them
//! sequentially in the closure. SQL is written as `const` strings; there is
//! no dynamic query construction anywhere.

pub mod auth;
pub mod bookshelf;
pub mod bookmarks;
pub mod cache;
pub mod feeds;
pub mod maintenance;
pub mod meta;
pub mod progress;

use tokio_rusqlite::rusqlite::Connection;

use crate::error::{Error, Result};

/// Deserialize a JSON payload stored in the database.
///
/// Corrupt payloads surface as `Error::Persistence(Database)` so callers can
/// clear the broken row and fall back to a fresh fetch.
pub(super) fn decode_json<T: serde::de::DeserializeOwned>(
    what: &str,
    json: &str,
) -> Result<T> {
    serde_json::from_str(json)
        .map_err(|e| Error::database(format!("corrupt {what} payload: {e}")))
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

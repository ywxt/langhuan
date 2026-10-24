//! SQLite storage layer.
//!
//! All persistent state — the feed registry, cached book data, the bookshelf,
//! reading progress, bookmarks, and auth payloads — lives in one SQLite
//! database file (`langhuan.db`).
//!
//! # Concurrency model
//!
//! A single [`tokio_rusqlite::Connection`] owns one dedicated OS thread.
//! Every operation is a closure sent through a channel and executed on that
//! thread, so all access is serialized without locks. Handles ([`Db`]) are
//! cheap clones of the channel sender.
//!
//! # Transactions
//!
//! [`Db::write`] is the only transaction boundary: the closure runs inside
//! `BEGIN … COMMIT`, and any error early-returns through `?`, dropping the
//! transaction and rolling it back. Repo methods are trait extensions on
//! `&Connection`, so composing several of them atomically is just calling
//! them sequentially inside one `write` closure. Nested transactions are
//! structurally impossible (closures are synchronous and cannot await).
//!
//! [`Db::call`] runs a closure without an explicit transaction — for
//! single-statement reads (and `last_used_at_ms` touches) this avoids the
//! overhead of `BEGIN`/`COMMIT`.

use std::path::Path;

use tokio_rusqlite::rusqlite::Connection;

use crate::error::{Error, Result};

pub mod maintenance;
pub mod repo;
mod schema;

/// A cheaply cloneable handle to the application database.
///
/// All clones share the same underlying connection (and therefore the same
/// dedicated thread) — cloning never creates a second database connection.
#[derive(Clone)]
pub struct Db {
    conn: tokio_rusqlite::Connection,
}

impl Db {
    /// Open (or create) the database file at `path`, apply pragmas, and run
    /// any pending schema migrations.
    pub async fn open(path: impl AsRef<Path>) -> Result<Self> {
        let conn = tokio_rusqlite::Connection::open(path)
            .await
            .map_err(|e| Error::database(e.to_string()))?;
        let db = Self { conn };
        db.initialize(false).await?;
        Ok(db)
    }

    /// Open a private in-memory database (used by tests).
    pub async fn open_in_memory() -> Result<Self> {
        let conn = tokio_rusqlite::Connection::open_in_memory()
            .await
            .map_err(|e| Error::database(e.to_string()))?;
        let db = Self { conn };
        db.initialize(true).await?;
        Ok(db)
    }

    async fn initialize(&self, in_memory: bool) -> Result<()> {
        self.run(move |conn| {
            apply_pragmas(conn, in_memory)?;
            schema::migrate(conn)?;
            tracing::debug!(version = schema::CURRENT_VERSION, "database ready");
            Ok(())
        })
        .await
    }

    /// Run a closure on the database thread without an explicit transaction.
    ///
    /// Intended for single-statement reads; the closure may also execute a
    /// single-statement write (e.g. a `last_used_at_ms` touch), which
    /// auto-commits.
    pub async fn call<T, F>(&self, f: F) -> Result<T>
    where
        F: FnOnce(&Connection) -> Result<T> + Send + 'static,
        T: Send + 'static,
    {
        self.run(move |conn| f(conn)).await
    }

    /// Run a closure inside a transaction.
    ///
    /// The closure receives a `&Connection` (a `Transaction` deref-coerced to
    /// one). If it returns `Err`, the transaction rolls back and the error
    /// propagates; otherwise it commits and the closure's value is returned.
    pub async fn write<T, F>(&self, f: F) -> Result<T>
    where
        F: FnOnce(&Connection) -> Result<T> + Send + 'static,
        T: Send + 'static,
    {
        self.run(move |conn| {
            let tx = conn.transaction()?;
            let result = f(&tx)?;
            tx.commit()?;
            Ok(result)
        })
        .await
    }

    /// Transport for closures to the dedicated database thread.
    ///
    /// Maps the two error layers: a closure error (`Error::Error`) is
    /// returned as-is; a transport failure (connection closed) becomes
    /// `Error::Persistence(Database)`, which in practice is unreachable
    /// because the connection is never closed while the app runs.
    async fn run<T, F>(&self, f: F) -> Result<T>
    where
        F: FnOnce(&mut Connection) -> Result<T> + Send + 'static,
        T: Send + 'static,
    {
        match self.conn.call(f).await {
            Ok(value) => Ok(value),
            Err(tokio_rusqlite::Error::Error(inner)) => Err(inner),
            Err(transport) => Err(Error::database(transport.to_string())),
        }
    }
}

/// Apply connection pragmas.
///
/// `journal_mode=WAL` and `auto_vacuum=INCREMENTAL` are stored in the
/// database file and only make sense for file-backed databases; in-memory
/// databases cannot use WAL.
fn apply_pragmas(conn: &mut Connection, in_memory: bool) -> Result<()> {
    let wal = if in_memory {
        ""
    } else {
        "PRAGMA journal_mode=WAL;"
    };
    let vacuum = if in_memory {
        ""
    } else {
        "PRAGMA auto_vacuum=INCREMENTAL;"
    };
    let mmap = if in_memory {
        ""
    } else {
        "PRAGMA mmap_size=67108864;"
    };
    // `execute_batch` tolerates pragmas that return rows (e.g. journal_mode).
    conn.execute_batch(&format!(
        "{wal}{vacuum}{mmap}\
         PRAGMA synchronous=NORMAL; \
         PRAGMA foreign_keys=ON; \
         PRAGMA busy_timeout=5000; \
         PRAGMA cache_size=-8000; \
         PRAGMA temp_store=MEMORY;"
    ))?;
    Ok(())
}

/// Milliseconds since the Unix epoch — the timestamp unit used across the
/// database schema.
pub fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Apply the full schema to a fresh connection (unit-test helper — the
/// production path is [`Db::open`], which runs the same migrations).
#[cfg(test)]
pub(crate) fn schema_for_tests(conn: &mut Connection) {
    schema::migrate(conn).expect("apply schema for tests");
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::repo::MetaRepo;

    #[tokio::test]
    async fn open_in_memory_runs_migrations() {
        let db = Db::open_in_memory().await.expect("open in-memory db");
        let version: i64 = db
            .call(|conn| Ok(conn.query_row("PRAGMA user_version", [], |row| row.get(0))?))
            .await
            .expect("read user_version");
        assert_eq!(version, schema::CURRENT_VERSION);

        // Re-opening must not fail or duplicate migrations.
        let version_again: i64 = db
            .call(|conn| Ok(conn.query_row("PRAGMA user_version", [], |row| row.get(0))?))
            .await
            .expect("read user_version again");
        assert_eq!(version_again, schema::CURRENT_VERSION);
    }

    #[tokio::test]
    async fn open_file_db_sets_wal_and_migrates() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("langhuan.db");
        let db = Db::open(&path).await.expect("open file db");

        let (mode, fk): (String, i64) = db
            .call(|conn| {
                let mode: String = conn.query_row("PRAGMA journal_mode", [], |row| row.get(0))?;
                let fk: i64 = conn.query_row("PRAGMA foreign_keys", [], |row| row.get(0))?;
                Ok((mode, fk))
            })
            .await
            .expect("read pragmas");
        assert_eq!(mode, "wal");
        assert_eq!(fk, 1);
        assert!(path.is_file());
        drop(db);
    }

    #[tokio::test]
    async fn write_rolls_back_on_error() {
        let db = Db::open_in_memory().await.expect("open");
        db.write(|conn| conn.set_meta("k", "v"))
            .await
            .expect("seed");

        // A failing closure must roll back everything it did.
        let result: Result<()> = db
            .write(|conn| {
                conn.set_meta("k", "changed")?;
                Err(Error::database("boom"))
            })
            .await;
        assert!(result.is_err());

        let value = db.call(|conn| conn.get_meta("k")).await.expect("read");
        assert_eq!(value.as_deref(), Some("v"));
    }

    #[tokio::test]
    async fn clones_share_one_connection() {
        let db = Db::open_in_memory().await.expect("open");
        let clone = db.clone();

        db.write(|conn| conn.set_meta("shared", "1"))
            .await
            .expect("write via original");

        let value = clone
            .call(|conn| conn.get_meta("shared"))
            .await
            .expect("read via clone");
        assert_eq!(value.as_deref(), Some("1"));
    }
}

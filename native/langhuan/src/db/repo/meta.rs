//! `meta` — small key-value metadata (e.g. `last_cleanup_ms`).

use tokio_rusqlite::rusqlite::Connection;

use crate::error::Result;

const GET: &str = "SELECT value FROM meta WHERE key = ?1";
const SET: &str = "INSERT INTO meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value";

/// Key-value metadata operations, as methods on [`Connection`].
pub trait MetaRepo {
    fn get_meta(&self, key: &str) -> Result<Option<String>>;

    fn set_meta(&self, key: &str, value: &str) -> Result<()>;

    /// Read a numeric metadata value; `default` when missing or malformed.
    fn get_meta_i64(&self, key: &str, default: i64) -> Result<i64>;
}

impl MetaRepo for Connection {
    fn get_meta(&self, key: &str) -> Result<Option<String>> {
        super::maybe_row(self, GET, &[&key], |row| row.get(0))
    }

    fn set_meta(&self, key: &str, value: &str) -> Result<()> {
        self.prepare_cached(SET)?.execute([key, value])?;
        Ok(())
    }

    fn get_meta_i64(&self, key: &str, default: i64) -> Result<i64> {
        Ok(self
            .get_meta(key)?
            .and_then(|v| v.parse().ok())
            .unwrap_or(default))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn conn() -> Connection {
        let conn = Connection::open_in_memory().expect("open");
        conn.execute_batch(
            "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;",
        )
        .expect("schema");
        conn
    }

    #[test]
    fn set_get_roundtrip() {
        let conn = conn();
        conn.set_meta("k", "v").expect("set");
        assert_eq!(conn.get_meta("k").expect("get").as_deref(), Some("v"));

        conn.set_meta("k", "v2").expect("overwrite");
        assert_eq!(conn.get_meta("k").expect("get").as_deref(), Some("v2"));
    }

    #[test]
    fn missing_key_returns_none() {
        let conn = conn();
        assert_eq!(conn.get_meta("nope").expect("get"), None);
    }

    #[test]
    fn get_meta_i64_defaults() {
        let conn = conn();
        assert_eq!(conn.get_meta_i64("n", 7).expect("get"), 7);
        conn.set_meta("n", "42").expect("set");
        assert_eq!(conn.get_meta_i64("n", 7).expect("get"), 42);
    }
}

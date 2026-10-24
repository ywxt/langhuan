//! `meta` — small key-value metadata (e.g. `last_cleanup_ms`).

use tokio_rusqlite::rusqlite::Connection;

use crate::error::Result;

const GET: &str = "SELECT value FROM meta WHERE key = ?1";
const SET: &str = "INSERT INTO meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value";

pub fn get(conn: &Connection, key: &str) -> Result<Option<String>> {
    super::maybe_row(conn, GET, &[&key], |row| row.get(0))
}

pub fn set(conn: &Connection, key: &str, value: &str) -> Result<()> {
    conn.prepare_cached(SET)?.execute([key, value])?;
    Ok(())
}

/// Read a numeric metadata value; `default` when missing or malformed.
pub fn get_i64(conn: &Connection, key: &str, default: i64) -> Result<i64> {
    Ok(get(conn, key)?.and_then(|v| v.parse().ok()).unwrap_or(default))
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
        set(&conn, "k", "v").expect("set");
        assert_eq!(get(&conn, "k").expect("get").as_deref(), Some("v"));

        set(&conn, "k", "v2").expect("overwrite");
        assert_eq!(get(&conn, "k").expect("get").as_deref(), Some("v2"));
    }

    #[test]
    fn missing_key_returns_none() {
        let conn = conn();
        assert_eq!(get(&conn, "nope").expect("get"), None);
    }

    #[test]
    fn get_i64_defaults() {
        let conn = conn();
        assert_eq!(get_i64(&conn, "n", 7).expect("get"), 7);
        set(&conn, "n", "42").expect("set");
        assert_eq!(get_i64(&conn, "n", 7).expect("get"), 42);
    }
}

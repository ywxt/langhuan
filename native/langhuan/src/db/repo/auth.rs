//! `auth` — one auth payload per feed, stored as JSON.

use tokio_rusqlite::rusqlite::Connection;

use crate::error::Result;

pub fn get(conn: &Connection, feed_id: &str) -> Result<Option<serde_json::Value>> {
    let json = super::maybe_row(
        conn,
        "SELECT cookies_json FROM auth WHERE feed_id = ?1",
        &[&feed_id],
        |row| row.get::<_, String>(0),
    )?;
    match json {
        Some(json) => {
            let value = serde_json::from_str(&json).map_err(|e| {
                // A corrupt payload is treated as absent; drop the broken row
                // so it does not wedge login forever.
                tracing::warn!(feed_id, error = %e, "corrupt auth payload — clearing");
                let _ = clear(conn, feed_id);
                crate::error::Error::database(format!("corrupt auth payload: {e}"))
            })?;
            Ok(Some(value))
        }
        None => Ok(None),
    }
}

pub fn set(
    conn: &Connection,
    feed_id: &str,
    value: &serde_json::Value,
    now_ms: i64,
) -> Result<()> {
    let json = serde_json::to_string(value)
        .map_err(|e| crate::error::Error::database(format!("serialize auth payload: {e}")))?;
    conn.prepare_cached(
        "INSERT INTO auth (feed_id, cookies_json, updated_at_ms) VALUES (?1, ?2, ?3) \
         ON CONFLICT(feed_id) DO UPDATE SET cookies_json = excluded.cookies_json, updated_at_ms = excluded.updated_at_ms",
    )?
    .execute(tokio_rusqlite::params![feed_id, json, now_ms])?;
    Ok(())
}

pub fn clear(conn: &Connection, feed_id: &str) -> Result<()> {
    conn.prepare_cached("DELETE FROM auth WHERE feed_id = ?1")?
        .execute([feed_id])?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::now_ms;

    fn conn() -> Connection {
        let conn = Connection::open_in_memory().expect("open");
        conn.execute_batch(
            "CREATE TABLE feeds (id TEXT PRIMARY KEY, name TEXT NOT NULL, version TEXT NOT NULL, author TEXT, source_url TEXT, content_hash TEXT NOT NULL, installed_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL) WITHOUT ROWID; \
             CREATE TABLE auth (feed_id TEXT PRIMARY KEY REFERENCES feeds(id) ON DELETE CASCADE, cookies_json TEXT NOT NULL, updated_at_ms INTEGER NOT NULL) WITHOUT ROWID;",
        )
        .expect("schema");
        conn.execute_batch("INSERT INTO feeds VALUES ('f1', 'Feed', '1.0', NULL, NULL, 'h', 1, 1);")
            .expect("seed");
        conn
    }

    #[test]
    fn roundtrip_and_clear() {
        let conn = conn();
        assert!(get(&conn, "f1").unwrap().is_none());

        let payload = serde_json::json!({"cookies": [{"name": "sid", "value": "abc"}]});
        set(&conn, "f1", &payload, now_ms()).unwrap();
        assert_eq!(get(&conn, "f1").unwrap(), Some(payload));

        clear(&conn, "f1").unwrap();
        assert!(get(&conn, "f1").unwrap().is_none());
    }
}

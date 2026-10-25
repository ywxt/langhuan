//! `auth` — one auth payload per feed, stored as JSON.

use tokio_rusqlite::rusqlite::Connection;

use crate::error::Result;

/// Auth-payload operations, as methods on [`Connection`].
pub trait AuthRepo {
    fn get_auth(&self, feed_id: &str) -> Result<Option<serde_json::Value>>;

    fn set_auth(&self, feed_id: &str, value: &serde_json::Value, now_ms: i64) -> Result<()>;

    fn clear_auth(&self, feed_id: &str) -> Result<()>;
}

impl AuthRepo for Connection {
    fn get_auth(&self, feed_id: &str) -> Result<Option<serde_json::Value>> {
        let json = super::maybe_row(
            self,
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
                    let _ = self.clear_auth(feed_id);
                    crate::error::Error::database(format!("corrupt auth payload: {e}"))
                })?;
                Ok(Some(value))
            }
            None => Ok(None),
        }
    }

    fn set_auth(&self, feed_id: &str, value: &serde_json::Value, now_ms: i64) -> Result<()> {
        let json = serde_json::to_string(value)
            .map_err(|e| crate::error::Error::database(format!("serialize auth payload: {e}")))?;
        self.prepare_cached(
            "INSERT INTO auth (feed_id, cookies_json, updated_at_ms) VALUES (?1, ?2, ?3) \
             ON CONFLICT(feed_id) DO UPDATE SET cookies_json = excluded.cookies_json, updated_at_ms = excluded.updated_at_ms",
        )?
        .execute(tokio_rusqlite::params![feed_id, json, now_ms])?;
        Ok(())
    }

    fn clear_auth(&self, feed_id: &str) -> Result<()> {
        self.prepare_cached("DELETE FROM auth WHERE feed_id = ?1")?
            .execute([feed_id])?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::now_ms;
    use crate::db::repo::test_support::TestDb;

    #[test]
    fn roundtrip_and_clear() {
        let db = TestDb::new();
        db.seed_feed("f1");
        let conn = db.conn();
        assert!(conn.get_auth("f1").unwrap().is_none());

        let payload = serde_json::json!({"cookies": [{"name": "sid", "value": "abc"}]});
        conn.set_auth("f1", &payload, now_ms()).unwrap();
        assert_eq!(conn.get_auth("f1").unwrap(), Some(payload));

        conn.clear_auth("f1").unwrap();
        assert!(conn.get_auth("f1").unwrap().is_none());
    }
}

//! `feed_storage` — per-feed key-value storage for feed scripts.
//!
//! Backs the `langhuan:storage` module: registered device credentials,
//! negotiated keys, sync points. One JSON value per (feed, key). Reads go
//! through the app-side in-memory cache, hydrated once from
//! [`all_feed_storage`](Self::all_feed_storage); [`set_feed_storage`] and
//! [`delete_feed_storage`] are applied asynchronously in submission order.

use super::Repo;
use crate::error::{Error, Result};

/// One stored entry: `(feed_id, key, value)`.
#[derive(Debug, Clone, PartialEq)]
pub struct FeedStorageEntry {
    pub feed_id: String,
    pub key: String,
    pub value: serde_json::Value,
}

impl Repo<'_> {
    /// Read every entry. Used to hydrate the app-side read cache when the
    /// database opens.
    ///
    /// A damaged payload is skipped with a warning rather than failing the
    /// hydration: one broken row must not blind the whole storage layer.
    pub fn all_feed_storage(&self) -> Result<Vec<FeedStorageEntry>> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT feed_id, key, value FROM feed_storage")?;
        let rows = stmt.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
            ))
        })?;
        let mut entries = Vec::new();
        for row in rows {
            let (feed_id, key, json) = row?;
            let value = match serde_json::from_str(&json) {
                Ok(value) => value,
                Err(error) => {
                    tracing::warn!(
                        feed_id,
                        key,
                        error = %error,
                        "corrupt feed storage payload — skipping"
                    );
                    continue;
                }
            };
            entries.push(FeedStorageEntry {
                feed_id,
                key,
                value,
            });
        }
        Ok(entries)
    }

    /// Store `value` under `(feed_id, key)`, replacing any previous value.
    pub fn set_feed_storage(
        &self,
        feed_id: &str,
        key: &str,
        value: &serde_json::Value,
    ) -> Result<()> {
        let json = serde_json::to_string(value)
            .map_err(|e| Error::database(format!("serialize feed storage payload: {e}")))?;
        self.conn
            .prepare_cached(
                "INSERT INTO feed_storage (feed_id, key, value) VALUES (?1, ?2, ?3) \
                 ON CONFLICT(feed_id, key) DO UPDATE SET value = excluded.value",
            )?
            .execute(tokio_rusqlite::params![feed_id, key, json])?;
        Ok(())
    }

    /// Remove `(feed_id, key)`; removing an absent key is not an error.
    pub fn delete_feed_storage(&self, feed_id: &str, key: &str) -> Result<()> {
        self.conn
            .prepare_cached("DELETE FROM feed_storage WHERE feed_id = ?1 AND key = ?2")?
            .execute(tokio_rusqlite::params![feed_id, key])?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use crate::db::repo::storage::FeedStorageEntry;
    use crate::db::repo::test_support::TestDb;

    fn entry(feed_id: &str, key: &str, value: serde_json::Value) -> FeedStorageEntry {
        FeedStorageEntry {
            feed_id: feed_id.to_owned(),
            key: key.to_owned(),
            value,
        }
    }

    #[test]
    fn set_all_and_delete_roundtrip() {
        let db = TestDb::new();
        db.seed_feed("f1");
        db.seed_feed("f2");
        let conn = db.repo();

        assert!(conn.all_feed_storage().unwrap().is_empty());

        conn.set_feed_storage("f1", "device", &serde_json::json!({"device_id": "d1"}))
            .unwrap();
        conn.set_feed_storage("f2", "keyinfo", &serde_json::json!({"keyver": 2}))
            .unwrap();
        // Overwrite keeps one row per (feed, key).
        conn.set_feed_storage("f1", "device", &serde_json::json!({"device_id": "d2"}))
            .unwrap();

        let mut rows = conn.all_feed_storage().unwrap();
        rows.sort_by(|a, b| a.feed_id.cmp(&b.feed_id));
        assert_eq!(
            rows,
            vec![
                entry("f1", "device", serde_json::json!({"device_id": "d2"})),
                entry("f2", "keyinfo", serde_json::json!({"keyver": 2})),
            ]
        );

        conn.delete_feed_storage("f1", "device").unwrap();
        // Deleting an absent key is not an error.
        conn.delete_feed_storage("f1", "device").unwrap();
        assert_eq!(conn.all_feed_storage().unwrap().len(), 1);
    }
}

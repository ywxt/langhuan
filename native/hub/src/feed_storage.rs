//! Per-feed key-value persistence for feed scripts — the app's
//! [`StorageHandler`] for the `langhuan:storage` module.
//!
//! The engine contract is synchronous and runs under the feed's realm
//! lock, so this implementation serves reads from an in-memory cache and
//! applies writes to SQLite asynchronously: a single writer task drains a
//! FIFO channel, so same-key overwrites keep their submission order. A
//! `set` returns when the value is visible to the feed, not when it is on
//! disk — a crash can lose the last few writes, and sources built on this
//! storage (device credentials, negotiated keys) simply re-register on the
//! next launch. That is the accepted trade for never blocking a runtime
//! worker on the async `Db` handle inside a realm lock.
//!
//! The singleton lives for the process lifetime and never drops; queued
//! writes die with the process — the same recovery as a crash, and a
//! `Drop` flush could not exist anyway: drop is synchronous while flush
//! must await the writer draining.
//!
//! Timing: the script engine (and this singleton) are constructed before
//! the app data directory exists, so [`FeedStorage::attach`] runs when the
//! database opens. Feeds live in the database, so no feed operation — and
//! no storage call — can precede that.

use std::collections::HashMap;
use std::sync::{Arc, OnceLock, RwLock};

use tokio::sync::mpsc;
#[cfg(test)]
use tokio::sync::oneshot;

use langhuan::db::Db;
use langhuan::error::{Error, Result};
use langhuan::feed::StorageHandler;
use serde_json::Value;

/// One feed's keys: `key → value`.
type Namespace = HashMap<Arc<str>, Value>;
/// The read cache: `feed_id → namespace`.
type Cache = HashMap<Arc<str>, Namespace>;

/// A pending persistence operation, applied in submission order.
enum Op {
    Set {
        feed_id: Arc<str>,
        key: Arc<str>,
        value: Value,
    },
    Delete {
        feed_id: Arc<str>,
        key: Arc<str>,
    },
    /// Barrier: acknowledged after every earlier operation has been
    /// applied (or dropped with a warning). Test-only — nothing in the
    /// app waits on persistence, feeds see their writes through the
    /// cache.
    #[cfg(test)]
    Flush(oneshot::Sender<()>),
}

/// Apply one queued operation to the database. The channel is FIFO, so
/// submission order is preserved; `Flush` only signals.
async fn apply(db: &Db, op: Op) -> Result<()> {
    match op {
        Op::Set {
            feed_id,
            key,
            value,
        } => {
            db.call(move |repo| repo.set_feed_storage(&feed_id, &key, &value))
                .await
        }
        Op::Delete { feed_id, key } => {
            db.call(move |repo| repo.delete_feed_storage(&feed_id, &key))
                .await
        }
        #[cfg(test)]
        Op::Flush(done) => {
            let _ = done.send(());
            Ok(())
        }
    }
}

/// The app's storage backend: a write-through read cache plus an async
/// SQLite writer.
pub struct FeedStorage {
    /// The read path: `(feed_id → (key → value))`.
    cache: RwLock<Cache>,
    /// Set by [`attach`](Self::attach); unset means the database has not
    /// opened yet, so no feed can run either.
    tx: OnceLock<mpsc::UnboundedSender<Op>>,
}

impl FeedStorage {
    fn new() -> Self {
        Self {
            cache: RwLock::new(HashMap::new()),
            tx: OnceLock::new(),
        }
    }

    /// The process-wide instance installed on the script engine.
    pub fn shared() -> Arc<Self> {
        static SHARED: OnceLock<Arc<FeedStorage>> = OnceLock::new();
        SHARED.get_or_init(|| Arc::new(Self::new())).clone()
    }

    /// Hydrate the read cache from `db` and start the async writer.
    ///
    /// Called once, when the app-data actor opens the database. A second
    /// call is ignored with a warning rather than re-hydrating over writes
    /// that have already happened this session.
    pub async fn attach(self: &Arc<Self>, db: Db) -> Result<()> {
        if self.tx.get().is_some() {
            tracing::warn!("feed storage already attached — ignoring duplicate");
            return Ok(());
        }

        let entries = db.call(|repo| repo.all_feed_storage()).await?;
        {
            let mut cache = self.lock_cache()?;
            for entry in entries {
                cache
                    .entry(Arc::from(entry.feed_id))
                    .or_default()
                    .insert(Arc::from(entry.key), entry.value);
            }
        }

        let (tx, mut rx) = mpsc::unbounded_channel();
        if self.tx.set(tx).is_err() {
            tracing::warn!("feed storage already attached — ignoring duplicate");
            return Ok(());
        }
        // The writer owns the database and the channel only — no Arc back
        // into this struct — so an instance that is not the process
        // singleton drops cleanly once its senders close.
        tokio::spawn(async move {
            while let Some(op) = rx.recv().await {
                if let Err(error) = apply(&db, op).await {
                    tracing::warn!(error = %error, "feed storage write dropped");
                }
            }
        });
        Ok(())
    }

    fn enqueue(&self, op: Op) -> Result<()> {
        let tx = self
            .tx
            .get()
            .ok_or_else(|| Error::database("feed storage is not attached to a database yet"))?;
        tx.send(op)
            .map_err(|_| Error::database("feed storage writer stopped"))
    }

    /// Wait until every operation submitted before this call has been
    /// applied (or dropped with a warning).
    ///
    /// Test-only, like the `Flush` barrier it sends: the app has no
    /// shutdown hook that would need to drain the writer.
    #[cfg(test)]
    pub async fn flush(&self) -> Result<()> {
        let (done_tx, done_rx) = oneshot::channel();
        self.enqueue(Op::Flush(done_tx))?;
        done_rx
            .await
            .map_err(|_| Error::database("feed storage writer stopped"))
    }

    fn lock_cache(&self) -> Result<std::sync::RwLockWriteGuard<'_, Cache>> {
        self.cache
            .write()
            .map_err(|_| Error::database("feed storage cache lock poisoned"))
    }

    fn read_cache(&self) -> Result<std::sync::RwLockReadGuard<'_, Cache>> {
        self.cache
            .read()
            .map_err(|_| Error::database("feed storage cache lock poisoned"))
    }
}

impl StorageHandler for FeedStorage {
    fn get(&self, feed_id: &str, key: &str) -> Result<Option<Value>> {
        let cache = self.read_cache()?;
        Ok(cache
            .get(feed_id)
            .and_then(|namespace| namespace.get(key))
            .cloned())
    }

    fn set(&self, feed_id: &str, key: &str, value: Value) -> Result<()> {
        // Queue the persist first: if the writer is not attached, the cache
        // stays untouched and the error is honest.
        self.enqueue(Op::Set {
            feed_id: Arc::from(feed_id),
            key: Arc::from(key),
            value: value.clone(),
        })?;
        let mut cache = self.lock_cache()?;
        cache
            .entry(Arc::from(feed_id))
            .or_default()
            .insert(Arc::from(key), value);
        Ok(())
    }

    fn delete(&self, feed_id: &str, key: &str) -> Result<()> {
        self.enqueue(Op::Delete {
            feed_id: Arc::from(feed_id),
            key: Arc::from(key),
        })?;
        let mut cache = self.lock_cache()?;
        if let Some(namespace) = cache.get_mut(feed_id) {
            namespace.remove(key);
            if namespace.is_empty() {
                cache.remove(feed_id);
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use langhuan::db::repo::FeedStorageEntry;

    /// An attached instance over an in-memory database seeded with two
    /// feeds (`feed_storage` rows reference `feeds(id)`).
    async fn attached() -> (Arc<FeedStorage>, Db) {
        let db = Db::open_in_memory().await.unwrap();
        for id in ["fanqie", "other"] {
            db.write(move |repo| {
                repo.conn().execute(
                    "INSERT INTO feeds (id, name, version, content_hash, installed_at_ms, updated_at_ms) \
                     VALUES (?1, ?1, '1', 'hash', 0, 0)",
                    [id],
                )?;
                Ok(())
            })
            .await
            .unwrap();
        }
        let storage = Arc::new(FeedStorage::new());
        storage.attach(db.clone()).await.unwrap();
        (storage, db)
    }

    #[tokio::test]
    async fn writes_are_visible_immediately_and_persist_asynchronously() {
        let (storage, db) = attached().await;

        assert!(storage.get("fanqie", "device").unwrap().is_none());

        // A set is visible to the next get without awaiting anything —
        // the read path is the cache.
        storage
            .set("fanqie", "device", serde_json::json!({"device_id": "d1"}))
            .unwrap();
        assert_eq!(
            storage.get("fanqie", "device").unwrap(),
            Some(serde_json::json!({"device_id": "d1"}))
        );

        // Overwrites and deletes keep their order.
        storage
            .set("fanqie", "device", serde_json::json!({"device_id": "d2"}))
            .unwrap();
        storage
            .set("fanqie", "keyinfo", serde_json::json!({"keyver": 2}))
            .unwrap();
        storage.delete("fanqie", "device").unwrap();
        assert!(storage.get("fanqie", "device").unwrap().is_none());
        assert_eq!(
            storage.get("fanqie", "keyinfo").unwrap(),
            Some(serde_json::json!({"keyver": 2}))
        );

        // After a flush, SQLite holds the surviving row — and only it.
        storage.flush().await.unwrap();
        let rows = db.call(|repo| repo.all_feed_storage()).await.unwrap();
        assert_eq!(
            rows,
            vec![FeedStorageEntry {
                feed_id: "fanqie".to_owned(),
                key: "keyinfo".to_owned(),
                value: serde_json::json!({"keyver": 2}),
            }]
        );
    }

    #[tokio::test]
    async fn attach_hydrates_the_cache_from_the_database() {
        // Persist through one instance, then attach a second instance to
        // the same database and observe it hydrated.
        let (first, db) = attached().await;
        first
            .set("fanqie", "device", serde_json::json!({"device_id": "d1"}))
            .unwrap();
        first.flush().await.unwrap();

        let second = Arc::new(FeedStorage::new());
        second.attach(db).await.unwrap();
        assert_eq!(
            second.get("fanqie", "device").unwrap(),
            Some(serde_json::json!({"device_id": "d1"}))
        );
    }

    #[tokio::test]
    async fn namespaces_are_isolated_per_feed() {
        let (storage, _db) = attached().await;
        storage
            .set("fanqie", "shared", serde_json::json!({"who": "fanqie"}))
            .unwrap();
        storage
            .set("other", "shared", serde_json::json!({"who": "other"}))
            .unwrap();
        assert_eq!(
            storage.get("fanqie", "shared").unwrap(),
            Some(serde_json::json!({"who": "fanqie"}))
        );
        assert_eq!(
            storage.get("other", "shared").unwrap(),
            Some(serde_json::json!({"who": "other"}))
        );
        // A key absent for one feed stays absent even when present for
        // another.
        assert_eq!(storage.get("other", "device").unwrap(), None);
    }
}

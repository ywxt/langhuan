//! Persistent per-feed key-value storage for feed scripts.
//!
//! A feed that talks to an app API often needs state that outlives a single
//! operation: registered device credentials, negotiated keys, or the point
//! a incremental sync reached. The host installs one [`StorageHandler`] on
//! the engine; every feed sees only its own keys, because the runtime stamps
//! each call with the calling feed's identifier — sources cannot address
//! another feed's namespace.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use serde_json::Value;

use crate::error::{Error, Result};

/// Host-provided key-value persistence, namespaced per feed.
///
/// Values are JSON, mirroring how auth payloads are stored. Calls run while
/// the feed's realm lock is held, so implementations must be fast (a single
/// indexed row) and must not call back into the feed.
pub trait StorageHandler: Send + Sync {
    /// Read the value stored under `key`, or `None` when absent.
    fn get(&self, feed_id: &str, key: &str) -> Result<Option<Value>>;
    /// Store `value` under `key`, replacing any previous value.
    fn set(&self, feed_id: &str, key: &str, value: Value) -> Result<()>;
    /// Remove `key`; removing an absent key is not an error.
    fn delete(&self, feed_id: &str, key: &str) -> Result<()>;
}

/// An [`Arc`] handle to a host storage backend.
pub type SharedStorageHandler = Arc<dyn StorageHandler>;

/// An in-memory [`StorageHandler`], namespaced by feed id.
///
/// Hosts that want a bounded or disposable storage environment install one
/// per environment: the developer tools build a fresh instance per debug
/// session, so a script that needs `langhuan:storage` becomes loadable
/// without touching any persistent backend, and everything written dies
/// with the handler — never with the app's data.
#[derive(Default)]
pub struct MemoryStorage(Mutex<HashMap<(String, String), Value>>);

impl MemoryStorage {
    pub fn new() -> Self {
        Self::default()
    }
}

fn poisoned() -> Error {
    Error::javascript("storage backend lock poisoned".to_owned())
}

impl StorageHandler for MemoryStorage {
    fn get(&self, feed_id: &str, key: &str) -> Result<Option<Value>> {
        Ok(self
            .0
            .lock()
            .map_err(|_| poisoned())?
            .get(&(feed_id.to_owned(), key.to_owned()))
            .cloned())
    }

    fn set(&self, feed_id: &str, key: &str, value: Value) -> Result<()> {
        self.0
            .lock()
            .map_err(|_| poisoned())?
            .insert((feed_id.to_owned(), key.to_owned()), value);
        Ok(())
    }

    fn delete(&self, feed_id: &str, key: &str) -> Result<()> {
        self.0
            .lock()
            .map_err(|_| poisoned())?
            .remove(&(feed_id.to_owned(), key.to_owned()));
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{MemoryStorage, StorageHandler};

    /// One handler namespaces feeds separately and starts empty.
    #[test]
    fn memory_storage_namespaces_by_feed() {
        let storage = MemoryStorage::new();
        assert!(storage.get("feed-a", "k").expect("get").is_none());
        storage
            .set("feed-a", "k", serde_json::json!({ "n": 1 }))
            .expect("set");
        storage
            .set("feed-b", "k", serde_json::json!({ "n": 2 }))
            .expect("set");
        let a = storage.get("feed-a", "k").expect("get").expect("present");
        let b = storage.get("feed-b", "k").expect("get").expect("present");
        assert_eq!(a["n"], 1);
        assert_eq!(b["n"], 2);

        storage.delete("feed-a", "k").expect("delete");
        assert!(storage.get("feed-a", "k").expect("get").is_none());
        assert!(
            storage.get("feed-b", "k").expect("get").is_some(),
            "deleting one feed's key must not touch another's"
        );
        // Deleting an absent key is not an error.
        storage.delete("feed-a", "k").expect("delete absent");
    }
}

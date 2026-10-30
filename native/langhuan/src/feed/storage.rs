//! Persistent per-feed key-value storage for feed scripts.
//!
//! A feed that talks to an app API often needs state that outlives a single
//! operation: registered device credentials, negotiated keys, or the point
//! a incremental sync reached. The host installs one [`StorageHandler`] on
//! the engine; every feed sees only its own keys, because the runtime stamps
//! each call with the calling feed's identifier — sources cannot address
//! another feed's namespace.

use std::sync::Arc;

use serde_json::Value;

use crate::error::Result;

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

use serde::{Deserialize, Serialize};

pub const AUTH_SCHEMA_VERSION: u32 = 1;

/// Auth payload persisted for one feed.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuthFile {
    pub schema_version: u32,
    pub feed_id: String,
    pub auth_info: serde_json::Value,
}

impl AuthFile {
    #[must_use]
    pub fn new(feed_id: String, auth_info: serde_json::Value) -> Self {
        Self {
            schema_version: AUTH_SCHEMA_VERSION,
            feed_id,
            auth_info,
        }
    }
}

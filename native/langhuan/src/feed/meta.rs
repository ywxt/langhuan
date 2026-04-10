use std::collections::HashSet;

use serde::Serialize;

/// The current feed script schema version supported by this application.
pub const FEED_SCHEMA_VERSION: u32 = 1;

/// Metadata extracted from the `==Feed==` header block of a feed script.
#[derive(Debug, Clone, Serialize)]
pub struct FeedMeta {
    /// Unique identifier for this feed.
    pub id: String,
    /// Display name of the feed (default locale).
    pub name: String,
    /// Version string (e.g. `"1.0.0"`).
    pub version: String,
    /// Author of the feed script.
    pub author: Option<String>,
    /// Short description (default locale).
    pub description: Option<String>,
    /// Base URL used by the feed. Available in Lua as `meta.base_url`.
    pub base_url: String,
    /// Access domain patterns for HTTP requests made by this feed.
    pub access_domains: HashSet<String>,
    /// Schema version declared by the feed script (`@schema_version`).
    pub schema_version: u32,
}

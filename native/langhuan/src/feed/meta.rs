use std::collections::HashSet;

use serde::Serialize;

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
    /// Allowed domain patterns for HTTP requests made by this feed.
    pub allowed_domains: HashSet<String>,
    /// Whether this feed claims to support remote bookshelf operations.
    pub supports_bookshelf: bool,
}
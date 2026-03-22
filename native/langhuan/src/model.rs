use std::collections::HashMap;

use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Paginated result (internal implementation detail)
// ---------------------------------------------------------------------------

/// A page of results with an opaque cursor for fetching the next page.
///
/// This type is used internally by [`LuaFeed`] to drive pagination.  Callers
/// of the public [`Feed`] trait never see `Page` — they receive a stream of
/// individual items instead.
///
/// `next_cursor` is determined entirely by the Lua feed script:
/// - `None` means this is the last page.
/// - `Some(cursor)` is an opaque value passed back to the next `*_request`
///   call. It can be a page number, a URL, a token, a table — whatever the
///   script needs.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct Page<T, C = String> {
    /// The items on this page.
    pub items: Vec<T>,
    /// An opaque cursor for the next page, or `None` if this is the last page.
    pub next_cursor: Option<C>,
}

// ---------------------------------------------------------------------------
// Domain models
// ---------------------------------------------------------------------------

/// A single search result returned by a feed.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchResult {
    /// Unique identifier for the book within this feed.
    pub id: String,
    /// Title of the book.
    pub title: String,
    /// Author of the book.
    pub author: String,
    /// URL to a cover image, if available.
    #[serde(default)]
    pub cover_url: Option<String>,
    /// A short description or summary, if available.
    #[serde(default)]
    pub description: Option<String>,
}

/// Detailed information about a book.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookInfo {
    /// Unique identifier for the book within this feed.
    pub id: String,
    /// Title of the book.
    pub title: String,
    /// Author of the book.
    pub author: String,
    /// URL to a cover image, if available.
    #[serde(default)]
    pub cover_url: Option<String>,
    /// A short description or summary, if available.
    #[serde(default)]
    pub description: Option<String>,
}

/// An entry in a book's table of contents.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChapterInfo {
    /// Unique identifier for the chapter within this feed.
    pub id: String,
    /// Title of the chapter.
    pub title: String,
    /// Zero-based index indicating the chapter's position in the book.
    pub index: u32,
}

/// The textual content of a single chapter.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChapterContent {
    /// Title of the chapter.
    pub title: String,
    /// The chapter body split into paragraphs.
    pub paragraphs: Vec<String>,
}

// ---------------------------------------------------------------------------
// HTTP request / response descriptors (Lua ↔ Rust boundary)
// ---------------------------------------------------------------------------

/// An HTTP request descriptor constructed by a Lua feed script.
///
/// The Lua `*_request` functions return a table that is deserialized into this
/// struct. Rust then executes the actual HTTP call.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HttpRequest {
    /// The target URL.
    pub url: String,
    /// HTTP method (GET, POST, …). Defaults to `"GET"`.
    #[serde(default = "default_method")]
    pub method: String,
    /// Query parameters appended to the URL.
    #[serde(default)]
    pub params: Option<HashMap<String, String>>,
    /// Additional HTTP headers.
    #[serde(default)]
    pub headers: Option<HashMap<String, String>>,
    /// An optional request body (for POST/PUT).
    #[serde(default)]
    pub body: Option<String>,
}

fn default_method() -> String {
    "GET".to_owned()
}

/// An HTTP response passed from Rust into a Lua `parse_*` function.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HttpResponse {
    /// HTTP status code.
    pub status: u16,
    /// Response headers.
    pub headers: HashMap<String, String>,
    /// The response body as a string.
    pub body: String,
    /// The final URL after any redirects.
    pub url: String,
}

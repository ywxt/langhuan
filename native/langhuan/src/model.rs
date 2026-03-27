use std::collections::HashMap;

use bytes::Bytes;
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

/// A single content unit in a chapter, emitted as part of a paragraphs stream.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Paragraph {
    /// The chapter title (typically emitted first).
    Title { text: String },
    /// A text paragraph.
    Text { content: String },
    /// An image.
    Image {
        url: String,
        #[serde(default)]
        alt: Option<String>,
    },
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
    /// An optional request body (for POST/PUT), as raw bytes.
    #[serde(default)]
    pub body: Option<HttpBody>,
}

/// A body carried by either an HTTP request or an HTTP response.
///
/// Raw bytes only — all encoding and decoding is the Lua script's responsibility.
/// On responses, Rust always delivers the raw bytes; Lua can call `json.decode`
/// or handle the string as needed.
#[derive(Debug, Clone)]
pub struct HttpBody(pub Bytes);

impl serde::Serialize for HttpBody {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_bytes(&self.0)
    }
}

impl<'de> serde::Deserialize<'de> for HttpBody {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        struct HttpBodyVisitor;

        impl<'de> serde::de::Visitor<'de> for HttpBodyVisitor {
            type Value = HttpBody;

            fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
                formatter.write_str("a byte array for HTTP body")
            }

            fn visit_bytes<E>(self, v: &[u8]) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                Ok(HttpBody(Bytes::copy_from_slice(v)))
            }

            fn visit_byte_buf<E>(self, v: Vec<u8>) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                Ok(HttpBody(Bytes::from(v)))
            }
        }

        deserializer.deserialize_bytes(HttpBodyVisitor)
    }
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
    /// The response body as raw bytes.
    pub body: HttpBody,
    /// The final URL after any redirects.
    pub url: String,
}

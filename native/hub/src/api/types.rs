//! Shared types exposed through the FRB bridge.
//!
//! These types are used by the `api/` functions and are automatically
//! translated to Dart classes by `flutter_rust_bridge_codegen`.

use std::collections::HashSet;

use flutter_rust_bridge::frb;

/// Unified error type for all bridge API calls.
///
/// FRB translates `Result<T, BridgeError>` into Dart exceptions automatically.
#[derive(Debug, Clone)]
#[frb(dart_code = r"
  @override
  String toString() => 'BridgeError: $message';
")]
pub struct BridgeError {
    pub message: String,
}

impl std::fmt::Display for BridgeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for BridgeError {}

impl From<String> for BridgeError {
    fn from(message: String) -> Self {
        Self { message }
    }
}

impl From<messages::prelude::SendError> for BridgeError {
    fn from(e: messages::prelude::SendError) -> Self {
        Self {
            message: format!("internal error: {e}"),
        }
    }
}

impl From<langhuan::error::Error> for BridgeError {
    fn from(e: langhuan::error::Error) -> Self {
        Self {
            message: crate::localize_error(&e),
        }
    }
}

// ---------------------------------------------------------------------------
// Registry / Feed types
// ---------------------------------------------------------------------------

pub struct FeedMetaItem {
    pub id: String,
    pub name: String,
    pub version: String,
    pub author: Option<String>,
    pub error: Option<String>,
}

pub struct FeedPreviewInfo {
    pub id: String,
    pub name: String,
    pub version: String,
    pub author: Option<String>,
    pub description: Option<String>,
    pub base_url: String,
    pub access_domains: HashSet<String>,
    pub current_version: Option<String>,
    pub schema_version: u32,
}

// ---------------------------------------------------------------------------
// Bookshelf types
// ---------------------------------------------------------------------------

pub enum BookshelfAddOutcome {
    Added,
    AlreadyExists,
}

pub enum BookshelfRemoveOutcome {
    Removed,
    NotFound,
}

pub struct BookshelfListItem {
    pub feed_id: String,
    pub source_book_id: String,
    pub title: String,
    pub author: String,
    pub cover_url: Option<String>,
    pub description_snapshot: Option<String>,
    pub added_at_unix_ms: i64,
}

// ---------------------------------------------------------------------------
// Feed stream types
// ---------------------------------------------------------------------------

pub struct SearchResultItem {
    pub id: String,
    pub title: String,
    pub author: String,
    pub cover_url: Option<String>,
    pub description: Option<String>,
}

pub struct ChapterItem {
    pub id: String,
    pub title: String,
    pub index: u32,
}

pub enum ParagraphContent {
    Title { text: String },
    Text { content: String },
    Image { url: String, alt: Option<String> },
}

pub struct BookInfo {
    pub id: String,
    pub title: String,
    pub author: String,
    pub cover_url: Option<String>,
    pub description: Option<String>,
}

// ---------------------------------------------------------------------------
// Auth types
// ---------------------------------------------------------------------------

pub enum AuthCapability {
    Supported,
    Unsupported,
}

pub struct AuthEntryInfo {
    pub url: String,
    pub title: Option<String>,
}

pub enum AuthStatus {
    LoggedIn,
    Expired,
    LoggedOut,
}

pub struct CookieEntry {
    pub name: String,
    pub value: String,
    pub domain: Option<String>,
    pub path: Option<String>,
    pub expires: Option<String>,
    pub secure: Option<bool>,
    pub http_only: Option<bool>,
    pub same_site: Option<String>,
}

// ---------------------------------------------------------------------------
// Reading progress types
// ---------------------------------------------------------------------------

pub struct ReadingProgressItem {
    pub feed_id: String,
    pub book_id: String,
    pub chapter_id: String,
    pub paragraph_index: u32,
    pub updated_at_ms: i64,
}

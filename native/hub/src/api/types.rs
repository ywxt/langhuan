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
  String toString() => 'BridgeError($kind): $message';
")]
pub struct BridgeError {
    pub kind: ErrorKind,
    pub message: String,
}

/// Classifies the error so Flutter can display appropriate UI.
#[derive(Debug, Clone)]
pub enum ErrorKind {
    /// Unclassified internal error.
    Internal,
    /// Network / HTTP failure (connection, timeout, 5xx).
    Network,
    /// Lua runtime error (a bug in the script).
    ScriptRuntime,
    /// Script configuration / loading error (missing function, bad metadata).
    ScriptConfig,
    /// An anticipated error raised by the script via `@langhuan/error`.
    ScriptExpected { reason: ScriptExpectedReason },
    /// Local storage I/O error.
    Storage,
    /// Feed registry error.
    Registry,
}

/// Sub-classification for script-expected errors.
#[derive(Debug, Clone)]
pub enum ScriptExpectedReason {
    AuthRequired,
    CfChallenge,
    RateLimited,
    ContentNotFound,
    SourceUnavailable,
    Other,
}

impl std::fmt::Display for BridgeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for BridgeError {}

impl From<String> for BridgeError {
    fn from(message: String) -> Self {
        Self {
            kind: ErrorKind::Internal,
            message,
        }
    }
}

impl From<messages::prelude::SendError> for BridgeError {
    fn from(e: messages::prelude::SendError) -> Self {
        Self {
            kind: ErrorKind::Internal,
            message: format!("internal error: {e}"),
        }
    }
}

impl From<langhuan::error::Error> for BridgeError {
    fn from(e: langhuan::error::Error) -> Self {
        use langhuan::error::{Error, ExpectedErrorCode, ScriptError};

        let kind = match &e {
            Error::Script(ScriptError::Expected { code, .. }) => {
                let reason = match code {
                    ExpectedErrorCode::AuthRequired => ScriptExpectedReason::AuthRequired,
                    ExpectedErrorCode::CfChallenge => ScriptExpectedReason::CfChallenge,
                    ExpectedErrorCode::RateLimited => ScriptExpectedReason::RateLimited,
                    ExpectedErrorCode::ContentNotFound => ScriptExpectedReason::ContentNotFound,
                    ExpectedErrorCode::SourceUnavailable => {
                        ScriptExpectedReason::SourceUnavailable
                    }
                    ExpectedErrorCode::Unknown(_) => ScriptExpectedReason::Other,
                };
                ErrorKind::ScriptExpected { reason }
            }
            Error::Script(ScriptError::Lua(_)) => ErrorKind::ScriptRuntime,
            Error::Script(_) => ErrorKind::ScriptConfig,
            Error::Http(_) => ErrorKind::Network,
            Error::Persistence(_) => ErrorKind::Storage,
            Error::Registry(_) => ErrorKind::Registry,
        };
        Self {
            kind,
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
}

/// Identifies a paragraph within a chapter.
pub enum ParagraphId {
    /// Sequential index assigned automatically when the source omits an id.
    Index(i64),
    /// Explicit identifier provided by the book source.
    Id(String),
}

impl ParagraphId {
    pub fn to_string_lossy(&self) -> String {
        match self {
            ParagraphId::Index(i) => i.to_string(),
            ParagraphId::Id(s) => s.clone(),
        }
    }

    pub fn from_stored(s: String) -> Self {
        match s.parse::<i64>() {
            Ok(i) => ParagraphId::Index(i),
            Err(_) => ParagraphId::Id(s),
        }
    }
}

impl From<langhuan::model::ParagraphId> for ParagraphId {
    fn from(id: langhuan::model::ParagraphId) -> Self {
        match id {
            langhuan::model::ParagraphId::Index(i) => ParagraphId::Index(i as i64),
            langhuan::model::ParagraphId::Id(s) => ParagraphId::Id(s),
        }
    }
}

pub enum ParagraphContent {
    Title { id: ParagraphId, text: String },
    Text { id: ParagraphId, content: String },
    Image { id: ParagraphId, url: String, alt: Option<String> },
}

// ---------------------------------------------------------------------------
// Chinese conversion types
// ---------------------------------------------------------------------------

/// Chinese text conversion mode, sent from Flutter.
pub enum ChineseConversionMode {
    /// No conversion — pass through unchanged.
    None,
    /// Simplified Chinese → Traditional Chinese.
    S2t,
    /// Traditional Chinese → Simplified Chinese.
    T2s,
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
    pub paragraph_id: ParagraphId,
    pub updated_at_ms: i64,
}

// ---------------------------------------------------------------------------
// Bookmark types
// ---------------------------------------------------------------------------

pub struct BookmarkItem {
    pub id: String,
    pub feed_id: String,
    pub book_id: String,
    pub chapter_id: String,
    pub paragraph_id: ParagraphId,
    pub paragraph_name: String,
    pub paragraph_preview: String,
    pub label: String,
    pub created_at_ms: i64,
}

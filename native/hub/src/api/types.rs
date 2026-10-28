//! Shared types exposed through the FRB bridge.
//!
//! These types are used by the `api/` functions and are automatically
//! translated to Dart classes by `flutter_rust_bridge_codegen`.

use std::collections::HashSet;

use flutter_rust_bridge::frb;

/// Unified error type for all bridge API calls.
///
/// FRB translates `Result<T, BridgeError>` into Dart exceptions automatically.
///
/// The Dart `toString` keeps the full `BridgeError($kind)` form: it is what
/// developer surfaces print — logs, `debugPrint`, Flutter's error panel,
/// uncaught-exception dumps — where the classification matters. User-facing
/// surfaces show the message alone through `normalizeErrorMessage` or the
/// structured fields.
#[derive(Debug, Clone)]
#[frb(dart_code = r"
  @override
  String toString() => 'BridgeError($kind): $message';
")]
pub struct BridgeError {
    pub kind: ErrorKind,
    pub message: String,
    /// For anticipated script errors ([`ErrorKind::ScriptExpected`]): the
    /// message the script itself provided, unwrapped from the localized
    /// presentation in `message`. `None` for every other kind — consumers
    /// then display `message` in full.
    pub detail: Option<String>,
}

/// Classifies the error so Flutter can display appropriate UI.
#[derive(Debug, Clone)]
pub enum ErrorKind {
    /// Unclassified internal error.
    Internal,
    /// Network / HTTP failure (connection, timeout, 5xx).
    Network,
    /// JavaScript runtime error (a bug or sandbox limit in the script).
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
    /// A code the script raised that this app does not know about. The
    /// code itself is the classification, so it is carried for display.
    Other {
        code: String,
    },
}

impl std::fmt::Display for BridgeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for BridgeError {}

impl BridgeError {
    /// Creates an anticipated script error classified by `reason`.
    ///
    /// `message` is an app-side presentation (already localized, not
    /// script-provided), so no `detail` is attached.
    pub fn script_expected(reason: ScriptExpectedReason, message: String) -> Self {
        Self {
            kind: ErrorKind::ScriptExpected { reason },
            message,
            detail: None,
        }
    }
}

impl From<String> for BridgeError {
    fn from(message: String) -> Self {
        Self {
            kind: ErrorKind::Internal,
            message,
            detail: None,
        }
    }
}

impl From<messages::prelude::SendError> for BridgeError {
    fn from(e: messages::prelude::SendError) -> Self {
        Self {
            kind: ErrorKind::Internal,
            message: format!("internal error: {e}"),
            detail: None,
        }
    }
}

impl From<langhuan::error::Error> for BridgeError {
    fn from(e: langhuan::error::Error) -> Self {
        use langhuan::error::{Error, ExpectedErrorCode, ScriptError};

        let (kind, detail) = match &e {
            Error::Script(ScriptError::Expected { code, message }) => {
                let reason = match code {
                    ExpectedErrorCode::AuthRequired => ScriptExpectedReason::AuthRequired,
                    ExpectedErrorCode::CfChallenge => ScriptExpectedReason::CfChallenge,
                    ExpectedErrorCode::RateLimited => ScriptExpectedReason::RateLimited,
                    ExpectedErrorCode::ContentNotFound => ScriptExpectedReason::ContentNotFound,
                    ExpectedErrorCode::SourceUnavailable => ScriptExpectedReason::SourceUnavailable,
                    ExpectedErrorCode::Unknown(code) => {
                        ScriptExpectedReason::Other { code: code.clone() }
                    }
                };
                (
                    ErrorKind::ScriptExpected { reason },
                    // The script's own words, unwrapped from the localized
                    // presentation: expected errors are classified data,
                    // not prose.
                    Some(message.clone()),
                )
            }
            Error::Script(ScriptError::JavaScript(_)) => (ErrorKind::ScriptRuntime, None),
            Error::Script(_) => (ErrorKind::ScriptConfig, None),
            Error::Http(_) => (ErrorKind::Network, None),
            Error::Persistence(_) => (ErrorKind::Storage, None),
            Error::Registry(_) => (ErrorKind::Registry, None),
        };
        Self {
            kind,
            detail,
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
    /// Paused feeds are excluded from aggregated search and background
    /// update checks, but explicit per-feed actions still work.
    pub enabled: bool,
    /// Where the feed script was installed from (URL), when known.
    pub source_url: Option<String>,
    /// Base URL declared by the feed script, cached into the database at
    /// install time. `None` only for feeds installed before the field was
    /// persisted.
    pub base_url: Option<String>,
    /// Access domain patterns declared by the feed script, cached into the
    /// database at install time and sorted for stable display. Empty when
    /// the feed declares no restriction.
    pub access_domains: Vec<String>,
    /// Description declared by the feed script, cached into the database
    /// at install time. `None` for feeds installed before the field was
    /// persisted and for scripts that declare none.
    pub description: Option<String>,
    pub error: Option<String>,
}

/// One entry of a feed-import preview: the script's own metadata plus how
/// its version relates to the installed one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FeedImportEntry {
    pub id: String,
    pub name: String,
    pub version: String,
    pub author: Option<String>,
    pub change: VersionChange,
}

/// One failed entry of a feed import (empty `id` when the script could not
/// even be parsed).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FeedImportFailure {
    pub id: String,
    pub error: String,
}

/// Summary of a feed import.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FeedImportOutcome {
    pub installed: u32,
    pub skipped: u32,
    pub failed: Vec<FeedImportFailure>,
}

/// How the version of a previewed script relates to the installed one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VersionChange {
    /// No installed version — this would be a new feed.
    New,
    /// Newer than the installed version.
    Upgrade,
    /// Older than the installed version.
    Downgrade,
    /// Identical to the installed version.
    Same,
    /// Either version string is not valid SemVer.
    Unknown,
}

pub struct FeedPreviewInfo {
    pub id: String,
    pub name: String,
    pub version: String,
    pub author: Option<String>,
    pub description: Option<String>,
    pub base_url: String,
    pub access_domains: HashSet<String>,
    /// Version of the currently installed script, if any.
    pub current_version: Option<String>,
    /// Relation between `version` and `current_version`.
    pub version_change: VersionChange,
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
    pub last_seen_chapters: i64,
    pub feed_enabled: bool,
    pub progress_current_chapter: Option<i64>,
    pub progress_total_chapters: Option<i64>,
    /// Title of the chapter the reader last stopped at, when known.
    pub progress_chapter_title: Option<String>,
    pub progress_current_paragraph: Option<i64>,
    pub progress_total_paragraphs: Option<i64>,
}

/// Per-book result of a bookshelf update check.
pub struct BookshelfUpdateItem {
    pub feed_id: String,
    pub source_book_id: String,
    /// Chapters published since the user last saw the book's chapter list.
    /// 0 means no update (or a baseline adopted on first check).
    pub new_chapters: i64,
    /// Set when this book's check failed (dead source, network, auth); the
    /// check continues with the remaining books.
    pub error: Option<String>,
}

// ---------------------------------------------------------------------------
// Cache statistics & maintenance types
// ---------------------------------------------------------------------------

/// Snapshot of database and cache statistics for the settings screen.
pub struct CacheStats {
    /// Payload bytes in the cache tables (chapters + chapter lists + covers).
    pub cache_bytes: i64,
    /// Total size of the database file.
    pub db_bytes: i64,
    pub book_count: i64,
    pub cover_count: i64,
    pub chapter_count: i64,
    pub chapter_list_count: i64,
    pub bookshelf_count: i64,
    pub feed_count: i64,
}

/// Outcome of a maintenance run or a full cache clear.
pub struct CleanupResult {
    /// `true` when the run was skipped by the 24 h throttle.
    pub skipped: bool,
    /// Rows removed (cache rows, stale progress, pruned script versions).
    pub items_removed: u64,
    /// Cache payload bytes freed.
    pub bytes_freed: i64,
    /// Book rows evicted by the 512 MiB size cap.
    pub books_evicted: u64,
}

/// Downloaded cover bytes for a book, read from the database.
pub struct CoverData {
    pub mime_type: String,
    pub bytes: Vec<u8>,
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

/// One event of an aggregated (all-installed-feeds) search.
///
/// Every installed feed runs its own search concurrently. `Item` carries
/// one result attributed to its source; `FeedError` reports that feed's
/// terminal failure — resolution or search — without affecting the other
/// feeds' contributions to the stream.
pub enum AggregatedSearchEvent {
    Item {
        feed_id: String,
        feed_name: String,
        item: SearchResultItem,
    },
    FeedError {
        feed_id: String,
        feed_name: String,
        error: String,
    },
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
    Title {
        id: ParagraphId,
        text: String,
    },
    Text {
        id: ParagraphId,
        content: String,
    },
    Image {
        id: ParagraphId,
        url: String,
        alt: Option<String>,
    },
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
    /// Simplified Chinese → Taiwan traditional, including local vocabulary.
    S2tw,
    /// Simplified Chinese → Hong Kong traditional.
    S2hk,
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
// WebView verification types
// ---------------------------------------------------------------------------

/// A verification page a feed asked the host to open for the user.
pub struct WebviewPrompt {
    pub request_id: u32,
    pub feed_id: String,
    pub feed_name: String,
    pub url: String,
    pub title: Option<String>,
}

// ---------------------------------------------------------------------------
// Reading progress types
// ---------------------------------------------------------------------------

pub struct ReadingProgressItem {
    pub feed_id: String,
    pub book_id: String,
    pub chapter_id: String,
    pub paragraph_id: ParagraphId,
    /// Character offset of the page-leading character within the paragraph
    /// (horizontal mode). 0 means the paragraph's start.
    pub paragraph_char_offset: u32,
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use langhuan::error::{Error, ExpectedErrorCode};

    use super::*;

    /// Expected script errors carry the script's own message as `detail`,
    /// classified by reason; the localized `message` still wraps it for
    /// end-user surfaces.
    #[test]
    fn expected_error_carries_script_detail() {
        let err = BridgeError::from(Error::expected(
            ExpectedErrorCode::AuthRequired,
            "VIP chapter needs login",
        ));

        let ErrorKind::ScriptExpected {
            reason: ScriptExpectedReason::AuthRequired,
        } = err.kind
        else {
            panic!("expected ScriptExpected/AuthRequired, got {:?}", err.kind);
        };
        assert_eq!(err.detail.as_deref(), Some("VIP chapter needs login"));
        assert!(
            err.message.contains("VIP chapter needs login"),
            "localized message still presents the script detail"
        );
    }

    /// A code this app does not know survives as `Other { code }` — the
    /// script's own classification is the display, not a generic "other".
    #[test]
    fn unknown_script_code_survives_as_other_with_code() {
        let err = BridgeError::from(Error::expected(
            ExpectedErrorCode::Unknown("waf".to_owned()),
            "blocked",
        ));

        let ErrorKind::ScriptExpected {
            reason: ScriptExpectedReason::Other { code },
        } = err.kind
        else {
            panic!("expected ScriptExpected/Other, got {:?}", err.kind);
        };
        assert_eq!(code, "waf");
        assert_eq!(err.detail.as_deref(), Some("blocked"));
    }

    /// Unexpected errors carry no `detail` — the full localized message is
    /// the display.
    #[test]
    fn unexpected_error_has_no_detail() {
        let err = BridgeError::from(Error::javascript("boom"));
        assert!(matches!(err.kind, ErrorKind::ScriptRuntime));
        assert!(err.detail.is_none());
    }

    /// The app-side constructor (login verification) is a presentation,
    /// not script-provided content: no `detail`.
    #[test]
    fn app_side_script_expected_has_no_detail() {
        let err = BridgeError::script_expected(
            ScriptExpectedReason::AuthRequired,
            "login could not be verified".to_owned(),
        );
        assert!(matches!(
            err.kind,
            ErrorKind::ScriptExpected {
                reason: ScriptExpectedReason::AuthRequired
            }
        ));
        assert!(err.detail.is_none());
    }
}

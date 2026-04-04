use std::collections::HashSet;

use rinf::{DartSignal, RustSignal, SignalPiece};
use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Feed signals — Dart → Rust (requests)
// ---------------------------------------------------------------------------

/// Request a search stream.  Rust will emit zero or more [`SearchResultItem`]
/// signals followed by exactly one [`FeedStreamEnd`] signal, all sharing the
/// same `request_id`.
#[derive(Deserialize, DartSignal)]
pub struct SearchRequest {
    /// Unique identifier for this request (UUID recommended).
    pub request_id: String,
    /// The feed script identifier to use.
    pub feed_id: String,
    /// The search keyword.
    pub keyword: String,
}

/// Request a chapters stream for a book.
#[derive(Deserialize, DartSignal)]
pub struct ChaptersRequest {
    pub request_id: String,
    pub feed_id: String,
    pub book_id: String,
}

/// Request a chapter-content stream.
#[derive(Deserialize, DartSignal)]
pub struct ChapterContentRequest {
    pub request_id: String,
    pub feed_id: String,
    pub chapter_id: String,
}

/// Request detailed information for a single book.
#[derive(Deserialize, DartSignal)]
pub struct BookInfoRequest {
    pub feed_id: String,
    pub book_id: String,
}

/// Cancel an in-progress stream identified by `request_id`.
/// Rust will stop emitting items and send a [`FeedStreamEnd`] with
/// `status = "cancelled"`.
#[derive(Deserialize, DartSignal)]
pub struct FeedCancelRequest {
    pub request_id: String,
}

// ---------------------------------------------------------------------------
// Feed signals — Rust → Dart (streamed results)
// ---------------------------------------------------------------------------

/// A single search result item emitted during a search stream.
#[derive(Serialize, RustSignal)]
pub struct SearchResultItem {
    pub request_id: String,
    pub id: String,
    pub title: String,
    pub author: String,
    pub cover_url: Option<String>,
    pub description: Option<String>,
}

/// A single chapter info item emitted during a chapters stream.
#[derive(Serialize, RustSignal)]
pub struct ChapterInfoItem {
    pub request_id: String,
    pub id: String,
    pub title: String,
    pub index: u32,
}

/// The content of a single paragraph in a chapter.
#[derive(Serialize, SignalPiece)]
pub enum ParagraphContent {
    Title { text: String },
    Text { content: String },
    Image { url: String, alt: Option<String> },
}

/// A single paragraph emitted during a chapter-content stream.
#[derive(Serialize, RustSignal)]
pub struct ChapterParagraphItem {
    pub request_id: String,
    pub paragraph: ParagraphContent,
}

/// The outcome of a book-info request.
#[derive(Serialize, SignalPiece)]
pub enum BookInfoOutcome {
    Success {
        id: String,
        title: String,
        author: String,
        cover_url: Option<String>,
        description: Option<String>,
    },
    Error {
        /// Human-readable error message.
        message: String,
    },
}

/// Response for a single [`BookInfoRequest`].
#[derive(Serialize, RustSignal)]
pub struct BookInfoResult {
    pub outcome: BookInfoOutcome,
}

/// The outcome of a feed stream.
#[derive(Serialize, SignalPiece)]
pub enum FeedStreamOutcome {
    Completed,
    Cancelled,
    Failed {
        /// Human-readable error message.
        error: String,
        /// Number of retry attempts made before the final outcome.
        retried_count: u32,
    },
}

/// Terminal signal for any feed stream.  Always emitted exactly once per
/// `request_id`, after all items (or immediately on cancellation/error).
#[derive(Serialize, RustSignal)]
pub struct FeedStreamEnd {
    pub request_id: String,
    pub outcome: FeedStreamOutcome,
}

// ---------------------------------------------------------------------------
// Registry signals — Dart → Rust
// ---------------------------------------------------------------------------

/// Tell Rust which directory should be used as the app data root.
/// Rust will store scripts and bookshelf data in dedicated subdirectories and
/// respond with [`AppDataDirectorySet`].
#[derive(Deserialize, DartSignal)]
pub struct SetAppDataDirectory {
    /// Absolute path to the app data root directory.
    pub path: String,
}

/// Request a listing of all feeds currently in the registry.
/// Rust will respond with [`FeedListResult`].
#[derive(Deserialize, DartSignal)]
pub struct ListFeedsRequest {
    /// Unique identifier for this request (UUID recommended).
    pub request_id: String,
}

// ---------------------------------------------------------------------------
// Registry signals — Rust → Dart
// ---------------------------------------------------------------------------

/// The outcome of setting the app data directory.
#[derive(Serialize, SignalPiece)]
pub enum AppDataDirectoryOutcome {
    Success {
        /// Number of feeds found in the registry.
        feed_count: u32,
    },
    Error {
        /// Human-readable error message.
        message: String,
    },
}

/// Confirmation that the app data directory has been initialized.
#[derive(Serialize, RustSignal)]
pub struct AppDataDirectorySet {
    pub outcome: AppDataDirectoryOutcome,
}

/// Metadata for a single feed entry, used inside [`FeedListResult`].
#[derive(Serialize, SignalPiece)]
pub struct FeedMetaItem {
    pub id: String,
    pub name: String,
    pub version: String,
    pub author: Option<String>,
    /// Compile error from `load_feed`, present only when the script failed to load.
    pub error: Option<String>,
}

/// Response to [`ListFeedsRequest`] — contains all registered feeds.
#[derive(Serialize, RustSignal)]
pub struct FeedListResult {
    pub request_id: String,
    pub items: Vec<FeedMetaItem>,
}

// ---------------------------------------------------------------------------
// Feed install signals — Dart → Rust (requests)
// ---------------------------------------------------------------------------

/// Request a preview of a feed script from a remote URL.
/// Rust will download the script, parse its metadata, and respond with
/// a [`FeedPreviewResult`].
#[derive(Deserialize, DartSignal)]
pub struct PreviewFeedFromUrl {
    pub request_id: String,
    pub url: String,
}

/// Request a preview of a feed script from a local file path.
/// Rust will read the file, parse its metadata, and respond with a
/// [`FeedPreviewResult`].
#[derive(Deserialize, DartSignal)]
pub struct PreviewFeedFromFile {
    pub request_id: String,
    /// Absolute path to the Lua script file on the device.
    pub path: String,
}

/// Set the locale used for Rust-side error messages.
/// Dart should call this once at startup and whenever the locale changes.
#[derive(Deserialize, DartSignal)]
pub struct SetLocale {
    /// BCP 47 locale tag, e.g. `"zh"`, `"zh-TW"`, `"en"`.
    pub locale: String,
}

/// Confirm installation of a previously previewed feed.
///
/// `request_id` must match the one from the preceding preview request.
/// Rust will write the script to disk, update `registry.toml`, apply the
/// change to the current in-memory registry, and respond with a
/// [`FeedInstallResult`].
#[derive(Deserialize, DartSignal)]
pub struct InstallFeedRequest {
    pub request_id: String,
}

/// Remove an installed feed by `feed_id`.
#[derive(Deserialize, DartSignal)]
pub struct RemoveFeedRequest {
    pub request_id: String,
    pub feed_id: String,
}

// ---------------------------------------------------------------------------
// Feed install signals — Rust → Dart (responses)
// ---------------------------------------------------------------------------

/// The outcome of a feed preview request.
#[derive(Serialize, SignalPiece)]
pub enum FeedPreviewOutcome {
    Success {
        id: String,
        name: String,
        version: String,
        author: Option<String>,
        description: Option<String>,
        base_url: String,
        /// Allowed domain patterns declared by the feed (`@allowed_domains`).
        /// Empty means no restriction.
        allowed_domains: HashSet<String>,
        /// The currently installed version, populated only when upgrading.
        current_version: Option<String>,
    },
    Error {
        /// Human-readable error message.
        message: String,
    },
}

/// Summary of a parsed feed script, sent in response to a preview request.
#[derive(Serialize, RustSignal)]
pub struct FeedPreviewResult {
    pub request_id: String,
    pub outcome: FeedPreviewOutcome,
}

/// The outcome of a feed install request.
#[derive(Serialize, SignalPiece)]
pub enum FeedInstallOutcome {
    Success,
    Error {
        /// Human-readable error message.
        message: String,
    },
}

/// Result of a [`InstallFeedRequest`].
#[derive(Serialize, RustSignal)]
pub struct FeedInstallResult {
    pub request_id: String,
    pub outcome: FeedInstallOutcome,
}

/// The outcome of a feed remove request.
#[derive(Serialize, SignalPiece)]
pub enum FeedRemoveOutcome {
    Success,
    Error {
        /// Human-readable error message.
        message: String,
    },
}

/// Result of a [`RemoveFeedRequest`].
#[derive(Serialize, RustSignal)]
pub struct FeedRemoveResult {
    pub request_id: String,
    pub outcome: FeedRemoveOutcome,
}

// ---------------------------------------------------------------------------
// Bookshelf signals — Dart -> Rust
// ---------------------------------------------------------------------------

#[derive(Deserialize, DartSignal)]
pub struct BookshelfAddRequest {
    pub request_id: String,
    pub feed_id: String,
    pub source_book_id: String,
    pub title: String,
    pub author: String,
    pub cover_url: Option<String>,
    pub description_snapshot: Option<String>,
}

#[derive(Deserialize, DartSignal)]
pub struct BookshelfRemoveRequest {
    pub request_id: String,
    pub feed_id: String,
    pub source_book_id: String,
}

#[derive(Deserialize, DartSignal)]
pub struct BookshelfListRequest {
    pub request_id: String,
}

#[derive(Deserialize, DartSignal)]
pub struct BookshelfCapabilitiesRequest {
    pub request_id: String,
    pub feed_id: String,
}

// ---------------------------------------------------------------------------
// Bookshelf signals — Rust -> Dart
// ---------------------------------------------------------------------------

#[derive(Serialize, SignalPiece)]
pub enum BookshelfOperationOutcome {
    Success,
    AlreadyExists,
    NotFound,
    Error { message: String },
}

#[derive(Serialize, RustSignal)]
pub struct BookshelfAddResult {
    pub request_id: String,
    pub outcome: BookshelfOperationOutcome,
}

#[derive(Serialize, RustSignal)]
pub struct BookshelfRemoveResult {
    pub request_id: String,
    pub outcome: BookshelfOperationOutcome,
}

#[derive(Serialize, RustSignal)]
pub struct BookshelfListItem {
    pub request_id: String,
    pub feed_id: String,
    pub source_book_id: String,
    pub title: String,
    pub author: String,
    pub cover_url: Option<String>,
    pub description_snapshot: Option<String>,
    pub added_at_unix_ms: i64,
}

#[derive(Serialize, SignalPiece)]
pub enum BookshelfListOutcome {
    Completed,
    Failed { message: String },
}

#[derive(Serialize, RustSignal)]
pub struct BookshelfListEnd {
    pub request_id: String,
    pub outcome: BookshelfListOutcome,
}

#[derive(Serialize, RustSignal)]
pub struct BookshelfCapabilitiesResult {
    pub request_id: String,
    pub feed_id: String,
    pub supports_bookshelf: bool,
}


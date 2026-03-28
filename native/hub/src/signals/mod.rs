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
#[serde(tag = "type", rename_all = "snake_case")]
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

/// The terminal status of a feed stream.
#[derive(Serialize, SignalPiece)]
pub enum FeedStreamStatus {
    Completed,
    Cancelled,
    Failed,
}

/// Terminal signal for any feed stream.  Always emitted exactly once per
/// `request_id`, after all items (or immediately on cancellation/error).
#[derive(Serialize, RustSignal)]
pub struct FeedStreamEnd {
    pub request_id: String,
    pub status: FeedStreamStatus,
    /// Human-readable error message, present only when `status == Failed`.
    pub error: Option<String>,
    /// Number of retry attempts made before the final outcome.
    pub retried_count: u32,
}

// ---------------------------------------------------------------------------
// Registry signals — Dart → Rust
// ---------------------------------------------------------------------------

/// Tell Rust which directory contains the scripts and `registry.toml`.
/// Rust will respond with [`ScriptDirectorySet`].
#[derive(Deserialize, DartSignal)]
pub struct SetScriptDirectory {
    /// Absolute path to the scripts directory.
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

/// Confirmation that the script directory has been (re-)loaded.
#[derive(Serialize, RustSignal)]
pub struct ScriptDirectorySet {
    /// `true` if the registry was loaded successfully.
    pub success: bool,
    /// Number of feeds found in the registry (0 on failure).
    pub feed_count: u32,
    /// Human-readable error message, present only when `success == false`.
    pub error: Option<String>,
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

/// Summary of a parsed feed script, sent in response to a preview request.
///
/// On success `error` is `None` and all other fields are populated.
/// On failure `error` is `Some(message)` and other fields may be empty.
#[derive(Serialize, RustSignal)]
pub struct FeedPreviewResult {
    pub request_id: String,
    pub id: String,
    pub name: String,
    pub version: String,
    pub author: Option<String>,
    pub description: Option<String>,
    pub base_url: String,
    /// Allowed domain patterns declared by the feed (`@allowed_domains`).
    /// Empty means no restriction.
    pub allowed_domains: Vec<String>,
    /// `true` if a feed with the same `id` is already installed (upgrade flow).
    pub is_upgrade: bool,
    /// The currently installed version, populated only when `is_upgrade` is `true`.
    pub current_version: Option<String>,
    /// Human-readable error message; present only on failure.
    pub error: Option<String>,
}

/// Result of a [`InstallFeedRequest`].
#[derive(Serialize, RustSignal)]
pub struct FeedInstallResult {
    pub request_id: String,
    pub success: bool,
    pub error: Option<String>,
}

/// Result of a [`RemoveFeedRequest`].
#[derive(Serialize, RustSignal)]
pub struct FeedRemoveResult {
    pub request_id: String,
    pub success: bool,
    pub error: Option<String>,
}


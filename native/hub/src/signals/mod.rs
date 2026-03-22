use rinf::{DartSignal, RustSignal, SignalPiece};
use serde::{Deserialize, Serialize};

/// To send data from Dart to Rust, use `DartSignal`.
#[derive(Deserialize, DartSignal)]
pub struct SmallText {
    pub text: String,
}

/// To send data from Rust to Dart, use `RustSignal`.
#[derive(Serialize, RustSignal)]
pub struct SmallNumber {
    pub number: i32,
}

/// A signal can be nested inside another signal.
#[derive(Serialize, RustSignal)]
pub struct BigBool {
    pub member: bool,
    pub nested: SmallBool,
}

/// To nest a signal inside other signal, use `SignalPiece`.
#[derive(Serialize, SignalPiece)]
pub struct SmallBool(pub bool);

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

/// A single chapter content segment emitted during a chapter-content stream.
#[derive(Serialize, RustSignal)]
pub struct ChapterContentItem {
    pub request_id: String,
    pub title: String,
    pub paragraphs: Vec<String>,
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
}

/// Response to [`ListFeedsRequest`] — contains all registered feeds.
#[derive(Serialize, RustSignal)]
pub struct FeedListResult {
    pub request_id: String,
    pub items: Vec<FeedMetaItem>,
}


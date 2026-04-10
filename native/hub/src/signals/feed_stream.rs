use rinf::{DartSignal, RustSignal, SignalPiece};
use serde::{Deserialize, Serialize};

/// Request a search stream. Rust will emit zero or more [`SearchResultItem`]
/// signals followed by exactly one [`FeedStreamEnd`] signal, all sharing the
/// same `request_id`.
#[derive(Deserialize, DartSignal)]
pub struct SearchRequest {
    pub request_id: String,
    pub feed_id: String,
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
    pub book_id: String,
    pub chapter_id: String,
}

/// Request detailed information for a single book.
#[derive(Deserialize, DartSignal)]
pub struct BookInfoRequest {
    pub feed_id: String,
    pub book_id: String,
}

/// Cancel an in-progress stream identified by `request_id`.
#[derive(Deserialize, DartSignal)]
pub struct FeedCancelRequest {
    pub request_id: String,
}

#[derive(Serialize, RustSignal)]
pub struct SearchResultItem {
    pub request_id: String,
    pub id: String,
    pub title: String,
    pub author: String,
    pub cover_url: Option<String>,
    pub description: Option<String>,
}

#[derive(Serialize, RustSignal)]
pub struct ChapterInfoItem {
    pub request_id: String,
    pub id: String,
    pub title: String,
    pub index: u32,
}

#[derive(Serialize, SignalPiece)]
pub enum ParagraphContent {
    Title { text: String },
    Text { content: String },
    Image { url: String, alt: Option<String> },
}

#[derive(Serialize, RustSignal)]
pub struct ChapterParagraphItem {
    pub request_id: String,
    pub paragraph: ParagraphContent,
}

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
        message: String,
    },
}

#[derive(Serialize, RustSignal)]
pub struct BookInfoResult {
    pub outcome: BookInfoOutcome,
}

#[derive(Serialize, SignalPiece)]
pub enum FeedStreamOutcome {
    Completed,
    Cancelled,
    Failed { error: String, retried_count: u32 },
}

#[derive(Serialize, RustSignal)]
pub struct FeedStreamEnd {
    pub request_id: String,
    pub outcome: FeedStreamOutcome,
}

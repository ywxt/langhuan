use rinf::{DartSignal, RustSignal, SignalPiece};
use serde::{Deserialize, Serialize};

#[derive(Deserialize, DartSignal)]
pub struct ReadingProgressGetRequest {
    pub request_id: String,
    pub feed_id: String,
    pub book_id: String,
}

#[derive(Deserialize, DartSignal)]
pub struct ReadingProgressSetRequest {
    pub request_id: String,
    pub feed_id: String,
    pub book_id: String,
    pub chapter_id: String,
    pub paragraph_index: u32,
    pub updated_at_ms: i64,
}

#[derive(Serialize, SignalPiece)]
pub struct ReadingProgressItem {
    pub feed_id: String,
    pub book_id: String,
    pub chapter_id: String,
    pub paragraph_index: u32,
    pub updated_at_ms: i64,
}

#[derive(Serialize, SignalPiece)]
pub enum ReadingProgressGetOutcome {
    Success {
        progress: Option<ReadingProgressItem>,
    },
    Error {
        message: String,
    },
}

#[derive(Serialize, RustSignal)]
pub struct ReadingProgressGetResult {
    pub request_id: String,
    pub outcome: ReadingProgressGetOutcome,
}

#[derive(Serialize, SignalPiece)]
pub enum ReadingProgressSetOutcome {
    Success,
    Error { message: String },
}

#[derive(Serialize, RustSignal)]
pub struct ReadingProgressSetResult {
    pub request_id: String,
    pub outcome: ReadingProgressSetOutcome,
}

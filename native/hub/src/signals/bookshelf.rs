use rinf::{DartSignal, RustSignal, SignalPiece};
use serde::{Deserialize, Serialize};

#[derive(Deserialize, DartSignal)]
pub struct BookshelfAddRequest {
    pub request_id: String,
    pub feed_id: String,
    pub source_book_id: String,
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

impl BookshelfAddResult {
    pub fn success(request_id: impl Into<String>) -> Self {
        Self {
            request_id: request_id.into(),
            outcome: BookshelfOperationOutcome::Success,
        }
    }

    pub fn already_exists(request_id: impl Into<String>) -> Self {
        Self {
            request_id: request_id.into(),
            outcome: BookshelfOperationOutcome::AlreadyExists,
        }
    }

    pub fn error(request_id: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            request_id: request_id.into(),
            outcome: BookshelfOperationOutcome::Error {
                message: message.into(),
            },
        }
    }
}

#[derive(Serialize, RustSignal)]
pub struct BookshelfRemoveResult {
    pub request_id: String,
    pub outcome: BookshelfOperationOutcome,
}

impl BookshelfRemoveResult {
    pub fn success(request_id: impl Into<String>) -> Self {
        Self {
            request_id: request_id.into(),
            outcome: BookshelfOperationOutcome::Success,
        }
    }

    pub fn not_found(request_id: impl Into<String>) -> Self {
        Self {
            request_id: request_id.into(),
            outcome: BookshelfOperationOutcome::NotFound,
        }
    }

    pub fn error(request_id: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            request_id: request_id.into(),
            outcome: BookshelfOperationOutcome::Error {
                message: message.into(),
            },
        }
    }
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

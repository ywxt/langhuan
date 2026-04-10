use rinf::{DartSignal, RustSignal, SignalPiece};
use serde::{Deserialize, Serialize};

use super::common::CookieEntry;

#[derive(Deserialize, DartSignal)]
pub struct FeedAuthCapabilityRequest {
    pub request_id: String,
    pub feed_id: String,
}

#[derive(Deserialize, DartSignal)]
pub struct FeedAuthEntryRequest {
    pub request_id: String,
    pub feed_id: String,
}

#[derive(Deserialize, DartSignal)]
pub struct FeedAuthSubmitPageRequest {
    pub request_id: String,
    pub feed_id: String,
    pub current_url: String,
    pub response: String,
    pub response_headers: Vec<(String, String)>,
    pub cookies: Vec<CookieEntry>,
}

#[derive(Deserialize, DartSignal)]
pub struct FeedAuthStatusRequest {
    pub request_id: String,
    pub feed_id: String,
}

#[derive(Deserialize, DartSignal)]
pub struct FeedAuthClearRequest {
    pub request_id: String,
    pub feed_id: String,
}

#[derive(Serialize, SignalPiece)]
pub enum FeedAuthCapabilityOutcome {
    Supported,
    Unsupported,
    Error { message: String },
}

#[derive(Serialize, RustSignal)]
pub struct FeedAuthCapabilityResult {
    pub request_id: String,
    pub outcome: FeedAuthCapabilityOutcome,
}

#[derive(Serialize, SignalPiece)]
pub enum FeedAuthEntryOutcome {
    Success { url: String, title: Option<String> },
    Unsupported,
    Error { message: String },
}

#[derive(Serialize, RustSignal)]
pub struct FeedAuthEntryResult {
    pub request_id: String,
    pub outcome: FeedAuthEntryOutcome,
}

#[derive(Serialize, SignalPiece)]
pub enum FeedAuthSubmitPageOutcome {
    Success,
    Unsupported,
    Error { message: String },
}

#[derive(Serialize, RustSignal)]
pub struct FeedAuthSubmitPageResult {
    pub request_id: String,
    pub outcome: FeedAuthSubmitPageOutcome,
}

#[derive(Serialize, SignalPiece)]
pub enum FeedAuthStatusOutcome {
    LoggedIn,
    Expired,
    LoggedOut,
    Error { message: String },
}

#[derive(Serialize, RustSignal)]
pub struct FeedAuthStatusResult {
    pub request_id: String,
    pub outcome: FeedAuthStatusOutcome,
}

#[derive(Serialize, SignalPiece)]
pub enum FeedAuthClearOutcome {
    Success,
    Error { message: String },
}

#[derive(Serialize, RustSignal)]
pub struct FeedAuthClearResult {
    pub request_id: String,
    pub outcome: FeedAuthClearOutcome,
}

impl FeedAuthCapabilityResult {
    pub fn supported(request_id: impl Into<String>) -> Self {
        Self {
            request_id: request_id.into(),
            outcome: FeedAuthCapabilityOutcome::Supported,
        }
    }

    pub fn unsupported(request_id: impl Into<String>) -> Self {
        Self {
            request_id: request_id.into(),
            outcome: FeedAuthCapabilityOutcome::Unsupported,
        }
    }

    pub fn error(request_id: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            request_id: request_id.into(),
            outcome: FeedAuthCapabilityOutcome::Error {
                message: message.into(),
            },
        }
    }
}

impl FeedAuthEntryResult {
    pub fn success(
        request_id: impl Into<String>,
        url: impl Into<String>,
        title: Option<String>,
    ) -> Self {
        Self {
            request_id: request_id.into(),
            outcome: FeedAuthEntryOutcome::Success {
                url: url.into(),
                title,
            },
        }
    }

    pub fn unsupported(request_id: impl Into<String>) -> Self {
        Self {
            request_id: request_id.into(),
            outcome: FeedAuthEntryOutcome::Unsupported,
        }
    }

    pub fn error(request_id: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            request_id: request_id.into(),
            outcome: FeedAuthEntryOutcome::Error {
                message: message.into(),
            },
        }
    }
}

impl FeedAuthSubmitPageResult {
    pub fn success(request_id: impl Into<String>) -> Self {
        Self {
            request_id: request_id.into(),
            outcome: FeedAuthSubmitPageOutcome::Success,
        }
    }

    pub fn unsupported(request_id: impl Into<String>) -> Self {
        Self {
            request_id: request_id.into(),
            outcome: FeedAuthSubmitPageOutcome::Unsupported,
        }
    }

    pub fn error(request_id: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            request_id: request_id.into(),
            outcome: FeedAuthSubmitPageOutcome::Error {
                message: message.into(),
            },
        }
    }
}

impl FeedAuthStatusResult {
    pub fn logged_in(request_id: impl Into<String>) -> Self {
        Self {
            request_id: request_id.into(),
            outcome: FeedAuthStatusOutcome::LoggedIn,
        }
    }

    pub fn expired(request_id: impl Into<String>) -> Self {
        Self {
            request_id: request_id.into(),
            outcome: FeedAuthStatusOutcome::Expired,
        }
    }

    pub fn logged_out(request_id: impl Into<String>) -> Self {
        Self {
            request_id: request_id.into(),
            outcome: FeedAuthStatusOutcome::LoggedOut,
        }
    }

    pub fn error(request_id: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            request_id: request_id.into(),
            outcome: FeedAuthStatusOutcome::Error {
                message: message.into(),
            },
        }
    }
}

impl FeedAuthClearResult {
    pub fn success(request_id: impl Into<String>) -> Self {
        Self {
            request_id: request_id.into(),
            outcome: FeedAuthClearOutcome::Success,
        }
    }

    pub fn error(request_id: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            request_id: request_id.into(),
            outcome: FeedAuthClearOutcome::Error {
                message: message.into(),
            },
        }
    }
}

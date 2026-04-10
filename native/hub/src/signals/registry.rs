use std::collections::HashSet;

use rinf::{DartSignal, RustSignal, SignalPiece};
use serde::{Deserialize, Serialize};

#[derive(Deserialize, DartSignal)]
pub struct SetAppDataDirectory {
    pub path: String,
}

#[derive(Deserialize, DartSignal)]
pub struct ListFeedsRequest {
    pub request_id: String,
}

#[derive(Serialize, SignalPiece)]
pub enum AppDataDirectoryOutcome {
    Success { feed_count: u32 },
    Error { message: String },
}

#[derive(Serialize, RustSignal)]
pub struct AppDataDirectorySet {
    pub outcome: AppDataDirectoryOutcome,
}

impl AppDataDirectorySet {
    pub fn success(feed_count: u32) -> Self {
        Self {
            outcome: AppDataDirectoryOutcome::Success { feed_count },
        }
    }

    pub fn error(message: impl Into<String>) -> Self {
        Self {
            outcome: AppDataDirectoryOutcome::Error {
                message: message.into(),
            },
        }
    }
}

#[derive(Serialize, SignalPiece)]
pub struct FeedMetaItem {
    pub id: String,
    pub name: String,
    pub version: String,
    pub author: Option<String>,
    pub error: Option<String>,
}

#[derive(Serialize, RustSignal)]
pub struct FeedListResult {
    pub request_id: String,
    pub items: Vec<FeedMetaItem>,
}

impl FeedListResult {
    pub fn new(request_id: impl Into<String>, items: Vec<FeedMetaItem>) -> Self {
        Self {
            request_id: request_id.into(),
            items,
        }
    }
}

#[derive(Deserialize, DartSignal)]
pub struct PreviewFeedFromUrl {
    pub request_id: String,
    pub url: String,
}

#[derive(Deserialize, DartSignal)]
pub struct PreviewFeedFromFile {
    pub request_id: String,
    pub path: String,
}

#[derive(Deserialize, DartSignal)]
pub struct InstallFeedRequest {
    pub request_id: String,
}

#[derive(Deserialize, DartSignal)]
pub struct RemoveFeedRequest {
    pub request_id: String,
    pub feed_id: String,
}

#[derive(Serialize, SignalPiece)]
pub enum FeedPreviewOutcome {
    Success {
        id: String,
        name: String,
        version: String,
        author: Option<String>,
        description: Option<String>,
        base_url: String,
        access_domains: HashSet<String>,
        current_version: Option<String>,
        schema_version: u32,
    },
    Error {
        message: String,
    },
}

#[derive(Serialize, RustSignal)]
pub struct FeedPreviewResult {
    pub request_id: String,
    pub outcome: FeedPreviewOutcome,
}

impl FeedPreviewResult {
    pub fn success(request_id: impl Into<String>, outcome: FeedPreviewOutcome) -> Self {
        Self {
            request_id: request_id.into(),
            outcome,
        }
    }

    pub fn error(request_id: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            request_id: request_id.into(),
            outcome: FeedPreviewOutcome::Error {
                message: message.into(),
            },
        }
    }
}

#[derive(Serialize, SignalPiece)]
pub enum FeedInstallOutcome {
    Success,
    Error { message: String },
}

#[derive(Serialize, RustSignal)]
pub struct FeedInstallResult {
    pub request_id: String,
    pub outcome: FeedInstallOutcome,
}

impl FeedInstallResult {
    pub fn success(request_id: impl Into<String>) -> Self {
        Self {
            request_id: request_id.into(),
            outcome: FeedInstallOutcome::Success,
        }
    }

    pub fn error(request_id: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            request_id: request_id.into(),
            outcome: FeedInstallOutcome::Error {
                message: message.into(),
            },
        }
    }
}

#[derive(Serialize, SignalPiece)]
pub enum FeedRemoveOutcome {
    Success,
    Error { message: String },
}

#[derive(Serialize, RustSignal)]
pub struct FeedRemoveResult {
    pub request_id: String,
    pub outcome: FeedRemoveOutcome,
}

impl FeedRemoveResult {
    pub fn success(request_id: impl Into<String>) -> Self {
        Self {
            request_id: request_id.into(),
            outcome: FeedRemoveOutcome::Success,
        }
    }

    pub fn error(request_id: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            request_id: request_id.into(),
            outcome: FeedRemoveOutcome::Error {
                message: message.into(),
            },
        }
    }
}

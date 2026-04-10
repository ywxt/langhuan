use std::future::Future;

use crate::error::Result;
use crate::http::HttpBody;

use super::traits::Feed;

/// Opaque auth payload parsed by feed login handlers.
pub type AuthInfo = serde_json::Value;

/// Data required to open a feed-specific login WebView flow.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct AuthEntry {
    pub url: String,
    #[serde(default)]
    pub title: Option<String>,
}

/// Page context submitted after WebView-based login completes.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct AuthPageContext {
    pub current_url: String,
    #[serde(default)]
    pub response: HttpBody,
    #[serde(default)]
    pub response_headers: Vec<(String, String)>,
    #[serde(default)]
    pub cookies: Vec<CookieEntry>,
}

/// Structured cookie item parsed from WebView/cookie manager.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct CookieEntry {
    pub name: String,
    pub value: String,
    #[serde(default)]
    pub domain: Option<String>,
    #[serde(default)]
    pub path: Option<String>,
    #[serde(default)]
    pub expires: Option<String>,
    #[serde(default)]
    pub secure: Option<bool>,
    #[serde(default)]
    pub http_only: Option<bool>,
    #[serde(default)]
    pub same_site: Option<String>,
}

/// Context for auth-aware request patching.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case")]
pub(crate) enum RequestPatchContext {
    Search {
        feed_id: String,
    },
    BookInfo {
        feed_id: String,
        book_id: String,
    },
    Chapters {
        feed_id: String,
        book_id: String,
    },
    AuthStatus {
        feed_id: String,
    },
    Paragraphs {
        feed_id: String,
        book_id: String,
        chapter_id: String,
    },
}

/// Current auth state for one feed instance.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthStatus {
    LoggedOut,
    LoggedIn,
    Expired,
}

/// Optional auth flow capability, kept separate from content [`Feed`] APIs.
pub trait FeedAuthFlow: Feed + Send + Sync {
    /// Proof token that auth handlers are supported by this feed instance.
    type SupportAuth: Clone + Send + Sync;

    /// Whether this feed supports auth flow handlers.
    fn supports_auth(&self) -> Option<Self::SupportAuth>;

    /// Optional entry payload used to start login UI.
    fn auth_entry(&self, support: &Self::SupportAuth) -> Result<AuthEntry>;

    /// Parse auth payload from a completed login page context.
    fn parse_auth(&self, support: &Self::SupportAuth, page: &AuthPageContext) -> Result<AuthInfo>;

    /// Set/replace current auth payload for this feed instance.
    fn set_auth_info(&self, support: &Self::SupportAuth, auth_info: Option<AuthInfo>)
    -> Result<()>;

    /// Return auth status for this feed instance.
    fn auth_status(
        &self,
        support: &Self::SupportAuth,
    ) -> impl Future<Output = Result<AuthStatus>> + Send;
}

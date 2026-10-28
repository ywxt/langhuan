//! Interactive WebView verification requested by feed scripts.
//!
//! A reducer can return a `webview` step when it reaches a state only a
//! human in a real browser can clear (anti-bot sliders, consent walls).
//! The host opens the requested page in a platform WebView, the user
//! completes the interaction, and the resulting page snapshot — final
//! URL, HTML, and cookies — is delivered back to the reducer as
//! `event.webview`, which then continues the operation like any other
//! step result.

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use super::auth_flow::CookieEntry;
use crate::error::Result;

/// A WebView page the feed asks the host to open for the user.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WebviewRequest {
    /// Feed identifier, stamped by the runtime for display purposes.
    pub feed_id: String,
    /// Feed display name, stamped by the runtime for display purposes.
    pub feed_name: String,
    /// Page to open.
    pub url: String,
    /// Optional UI title for the verification surface.
    pub title: Option<String>,
}

/// The page snapshot delivered back to the reducer once the user
/// finishes in the WebView.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WebviewSnapshot {
    /// Final URL of the page.
    pub current_url: String,
    /// Final page HTML.
    pub html: String,
    /// Cookies visible to the visited hosts after the interaction.
    pub cookies: Vec<CookieEntry>,
}

/// Future returned by [`WebviewHandler::open`].
pub type WebviewFuture = Pin<Box<dyn Future<Output = Result<WebviewSnapshot>> + Send>>;

/// Host-side provider for interactive WebView verification.
///
/// Installed by the application host on every compiled feed; tests
/// install their own to drive the flow deterministically. The operation
/// awaits the returned future for as long as the user needs; returning
/// `Err` aborts it (for example, the user closed the page).
pub trait WebviewHandler: Send + Sync {
    fn open(&self, request: WebviewRequest) -> WebviewFuture;
}

/// Shared handler handle used by [`crate::script::js`] internals.
pub type SharedWebviewHandler = Arc<dyn WebviewHandler>;

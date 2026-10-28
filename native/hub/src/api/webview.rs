//! WebView verification prompts: the app opens one prompt stream at
//! startup and answers each prompt by completing or canceling it.

use tokio::sync::mpsc::UnboundedReceiver;

use crate::actors::{
    addresses,
    webview_actor::{CancelWebview, CompleteWebview, SubscribeWebviewPrompts},
};

use super::types::{BridgeError, CookieEntry, WebviewPrompt};

/// A pull-based stream of WebView verification prompts.
pub struct WebviewPromptStream {
    receiver: UnboundedReceiver<WebviewPrompt>,
}

impl WebviewPromptStream {
    pub async fn next(&mut self) -> Result<Option<WebviewPrompt>, BridgeError> {
        Ok(self.receiver.recv().await)
    }

    pub fn cancel(&mut self) {
        // Closing the receiving half makes the actor's sends fail, which
        // turns any later verification request into an operation error.
        self.receiver.close();
    }
}

/// Subscribe to verification prompts. Replaces the previous listener, if
/// any — the app keeps exactly one open stream.
pub async fn open_webview_prompt_stream() -> Result<WebviewPromptStream, BridgeError> {
    let receiver = addresses()?
        .webview
        .clone()
        .send(SubscribeWebviewPrompts)
        .await??;
    Ok(WebviewPromptStream { receiver })
}

/// Report the page snapshot after the user finished verifying. Returns
/// `false` when the id is unknown (stale prompt or already answered).
pub async fn complete_webview(
    request_id: u32,
    current_url: String,
    html: String,
    cookies: Vec<CookieEntry>,
) -> Result<bool, BridgeError> {
    addresses()?
        .webview
        .clone()
        .send(CompleteWebview {
            request_id,
            current_url,
            html,
            cookies,
        })
        .await?
}

/// Report that the user abandoned the verification page. Returns `false`
/// when the id is unknown (stale prompt or already answered).
pub async fn cancel_webview(request_id: u32) -> Result<bool, BridgeError> {
    addresses()?
        .webview
        .clone()
        .send(CancelWebview { request_id })
        .await?
}

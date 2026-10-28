//! Coordinates interactive WebView verification between feed scripts and
//! the UI.
//!
//! When a feed reducer returns a `webview` step, the [`WebviewBridge`]
//! handler installed on every compiled feed forwards the request here.
//! The actor pushes a [`WebviewPrompt`] to the single Dart-side listener
//! and parks the operation on a oneshot channel until the UI reports the
//! page snapshot (or the user cancels).

use std::collections::HashMap;

use async_trait::async_trait;
use messages::actor::Actor;
use messages::prelude::{Address, Context, Handler};
use tokio::sync::{mpsc, oneshot};

use langhuan::error::{Error as FeedError, ExpectedErrorCode};
use langhuan::feed::{
    CookieEntry as FeedCookieEntry, WebviewFuture, WebviewHandler, WebviewRequest,
    WebviewSnapshot,
};

use crate::api::types::{BridgeError, CookieEntry, WebviewPrompt};

/// Capacity of the prompt channel towards the UI listener. Prompts are
/// rare (at most one per gated operation) and are presented one at a time;
/// a bound keeps a stuck listener from buffering work without limit. A
/// full queue fails the newest prompt instead of blocking the actor, which
/// would deadlock Dart-side completes waiting behind the send.
const PROMPT_CHANNEL_CAPACITY: usize = 32;

/// Message from a feed's webview handler: open a verification page.
pub struct OpenWebview {
    pub request: WebviewRequest,
}

/// Message from Dart: subscribe to verification prompts. The app opens one
/// prompt stream at startup; a new subscription replaces the old one.
pub struct SubscribeWebviewPrompts;

/// Message from Dart: the user finished in the WebView.
pub struct CompleteWebview {
    pub request_id: u32,
    pub current_url: String,
    pub html: String,
    pub cookies: Vec<CookieEntry>,
}

/// Message from Dart: the user abandoned the WebView.
pub struct CancelWebview {
    pub request_id: u32,
}

pub struct WebviewActor {
    next_id: u32,
    /// Parked operations awaiting a UI verdict, keyed by prompt id.
    pending: HashMap<u32, oneshot::Sender<Result<WebviewSnapshot, String>>>,
    /// The single Dart-side prompt listener.
    listener: Option<mpsc::Sender<WebviewPrompt>>,
}

impl WebviewActor {
    pub fn new() -> Self {
        Self {
            next_id: 0,
            pending: HashMap::new(),
            listener: None,
        }
    }
}

impl Actor for WebviewActor {}

#[async_trait]
impl Handler<OpenWebview> for WebviewActor {
    type Result = Result<oneshot::Receiver<Result<WebviewSnapshot, String>>, BridgeError>;

    async fn handle(&mut self, message: OpenWebview, _: &Context<Self>) -> Self::Result {
        let listener = self.listener.as_ref().ok_or_else(|| {
            BridgeError::from("no WebView listener attached — open a prompt stream first".to_owned())
        })?;
        let request_id = self.next_id;
        self.next_id = self.next_id.wrapping_add(1);
        let (sender, receiver) = oneshot::channel();
        self.pending.insert(request_id, sender);
        let prompt = WebviewPrompt {
            request_id,
            feed_id: message.request.feed_id,
            feed_name: message.request.feed_name,
            url: message.request.url,
            title: message.request.title,
        };
        // try_send keeps the actor non-blocking: an awaiting send would
        // queue Dart-side completes behind it and deadlock the flow.
        if let Err(error) = listener.try_send(prompt) {
            self.pending.remove(&request_id);
            match error {
                mpsc::error::TrySendError::Full(_) => {
                    tracing::warn!("webview prompt queue is full");
                    return Err(BridgeError::from(
                        "too many pending WebView verifications".to_owned(),
                    ));
                }
                mpsc::error::TrySendError::Closed(_) => {
                    tracing::warn!("webview prompt listener closed while prompting");
                    return Err(BridgeError::from(
                        "WebView prompt stream is closed".to_owned(),
                    ));
                }
            }
        }
        tracing::debug!(request_id, "webview verification requested");
        Ok(receiver)
    }
}

#[async_trait]
impl Handler<SubscribeWebviewPrompts> for WebviewActor {
    type Result = Result<mpsc::Receiver<WebviewPrompt>, BridgeError>;

    async fn handle(&mut self, _: SubscribeWebviewPrompts, _: &Context<Self>) -> Self::Result {
        let (sender, receiver) = mpsc::channel(PROMPT_CHANNEL_CAPACITY);
        self.listener = Some(sender);
        tracing::debug!("webview prompt listener attached");
        Ok(receiver)
    }
}

#[async_trait]
impl Handler<CompleteWebview> for WebviewActor {
    type Result = Result<bool, BridgeError>;

    async fn handle(&mut self, message: CompleteWebview, _: &Context<Self>) -> Self::Result {
        let sender = self.pending.remove(&message.request_id);
        let Some(sender) = sender else {
            return Ok(false);
        };
        let snapshot = WebviewSnapshot {
            current_url: message.current_url,
            html: message.html,
            cookies: message
                .cookies
                .into_iter()
                .map(|item| FeedCookieEntry {
                    name: item.name,
                    value: item.value,
                    domain: item.domain,
                    path: item.path,
                    expires: item.expires,
                    secure: item.secure,
                    http_only: item.http_only,
                    same_site: item.same_site,
                })
                .collect(),
        };
        let delivered = sender.send(Ok(snapshot)).is_ok();
        if delivered {
            tracing::debug!(request_id = message.request_id, "webview verification done");
        }
        Ok(delivered)
    }
}

#[async_trait]
impl Handler<CancelWebview> for WebviewActor {
    type Result = Result<bool, BridgeError>;

    async fn handle(&mut self, message: CancelWebview, _: &Context<Self>) -> Self::Result {
        let sender = self.pending.remove(&message.request_id);
        let Some(sender) = sender else {
            return Ok(false);
        };
        let delivered = sender
            .send(Err("verification canceled".to_owned()))
            .is_ok();
        if delivered {
            tracing::debug!(request_id = message.request_id, "webview verification canceled");
        }
        Ok(delivered)
    }
}

/// langhuan-side handler installed on every compiled feed; routes webview
/// steps to the actor and awaits the user's verdict.
struct WebviewBridge {
    address: Address<WebviewActor>,
}

impl WebviewBridge {
    fn new(address: Address<WebviewActor>) -> Self {
        Self { address }
    }
}

fn verification_error(message: impl std::fmt::Display) -> FeedError {
    FeedError::expected(ExpectedErrorCode::AuthRequired, message.to_string())
}

impl WebviewHandler for WebviewBridge {
    fn open(&self, request: WebviewRequest) -> WebviewFuture {
        let mut address = self.address.clone();
        Box::pin(async move {
            let receiver = match address.send(OpenWebview { request }).await {
                Ok(Ok(receiver)) => receiver,
                Ok(Err(error)) => return Err(verification_error(error.message)),
                Err(error) => return Err(verification_error(error)),
            };
            match receiver.await {
                Ok(Ok(snapshot)) => Ok(snapshot),
                Ok(Err(message)) => Err(verification_error(message)),
                Err(_) => Err(verification_error(
                    "verification page was closed before completion",
                )),
            }
        })
    }
}

/// Installs the hub's webview handler on one compiled feed. Called on every
/// compile path so any feed can request verification.
pub(crate) fn attach_webview_handler(
    feed: &langhuan::script::feed::ScriptFeed,
    address: &Address<WebviewActor>,
) -> langhuan::error::Result<()> {
    feed.set_webview_handler(Some(std::sync::Arc::new(WebviewBridge::new(address.clone()))))
}

#[cfg(test)]
mod tests {
    use messages::prelude::Handler;

    use super::*;

    #[tokio::test]
    async fn prompt_round_trip_and_cancellation() {
        let mut actor = WebviewActor::new();

        let mut prompts = actor
            .handle(SubscribeWebviewPrompts, &Context::new())
            .await
            .expect("subscribe");

        // No listener error path first.
        let mut lone = WebviewActor::new();
        let error = lone
            .handle(
                OpenWebview {
                    request: WebviewRequest {
                        feed_id: "f".into(),
                        feed_name: "Feed".into(),
                        url: "https://example.com/v".into(),
                        title: None,
                    },
                },
                &Context::new(),
            )
            .await
            .expect_err("must fail without a listener");
        assert!(error.message.contains("no WebView listener"));

        // Request → prompt → complete.
        let receiver = actor
            .handle(
                OpenWebview {
                    request: WebviewRequest {
                        feed_id: "fanqie".into(),
                        feed_name: "番茄小說".into(),
                        url: "https://example.com/verify".into(),
                        title: Some("Verify".into()),
                    },
                },
                &Context::new(),
            )
            .await
            .expect("open");
        let prompt = prompts.recv().await.expect("prompt delivered");
        assert_eq!(prompt.feed_id, "fanqie");
        assert_eq!(prompt.url, "https://example.com/verify");
        assert_eq!(prompt.title.as_deref(), Some("Verify"));

        let delivered = actor
            .handle(
                CompleteWebview {
                    request_id: prompt.request_id,
                    current_url: "https://example.com/done".into(),
                    html: "<html/>".into(),
                    cookies: vec![CookieEntry {
                        name: "msToken".into(),
                        value: "tok".into(),
                        domain: None,
                        path: None,
                        expires: None,
                        secure: None,
                        http_only: None,
                        same_site: None,
                    }],
                },
                &Context::new(),
            )
            .await
            .expect("complete");
        assert!(delivered);
        let snapshot = receiver.await.expect("sender alive").expect("snapshot");
        assert_eq!(snapshot.current_url, "https://example.com/done");
        assert_eq!(snapshot.cookies[0].value, "tok");

        // Unknown ids report false instead of erroring.
        let unknown = actor
            .handle(
                CancelWebview { request_id: 9999 },
                &Context::new(),
            )
            .await
            .expect("cancel");
        assert!(!unknown);

        // Request → prompt → cancel.
        let receiver = actor
            .handle(
                OpenWebview {
                    request: WebviewRequest {
                        feed_id: "fanqie".into(),
                        feed_name: "番茄小說".into(),
                        url: "https://example.com/verify".into(),
                        title: None,
                    },
                },
                &Context::new(),
            )
            .await
            .expect("open");
        let prompt = prompts.recv().await.expect("prompt delivered");
        actor
            .handle(CancelWebview { request_id: prompt.request_id }, &Context::new())
            .await
            .expect("cancel");
        let error = receiver.await.expect("sender alive").expect_err("canceled");
        assert_eq!(error, "verification canceled");
    }

    #[tokio::test]
    async fn prompt_queue_is_bounded() {
        let request = || WebviewRequest {
            feed_id: "fanqie".into(),
            feed_name: "番茄小說".into(),
            url: "https://example.com/verify".into(),
            title: None,
        };

        // An unanswered listener accumulates up to the channel capacity…
        let mut saturated = WebviewActor::new();
        let mut prompts = saturated
            .handle(SubscribeWebviewPrompts, &Context::new())
            .await
            .expect("subscribe");
        for _ in 0..super::PROMPT_CHANNEL_CAPACITY {
            saturated
                .handle(
                    OpenWebview {
                        request: request(),
                    },
                    &Context::new(),
                )
                .await
                .expect("open within capacity");
        }
        // …and the next prompt fails the operation instead of buffering.
        let error = saturated
            .handle(
                OpenWebview {
                    request: request(),
                },
                &Context::new(),
            )
            .await
            .expect_err("queue must be full");
        assert!(error.message.contains("too many pending WebView verifications"));

        // The listener consuming one prompt frees a slot.
        prompts.recv().await.expect("one prompt consumed");
        saturated
            .handle(
                OpenWebview {
                    request: request(),
                },
                &Context::new(),
            )
            .await
            .expect("slot freed after consumption");
    }
}

use super::types::{AuthCapability, AuthEntryInfo, AuthStatus, BridgeError, CookieEntry};
use crate::actors::{
    addresses,
    login_actor::{
        FeedAuthCapabilityMsg, FeedAuthClearMsg, FeedAuthEntryMsg, FeedAuthStatusMsg,
        FeedAuthSubmitPageMsg,
    },
};

pub async fn feed_auth_capability(feed_id: String) -> Result<AuthCapability, BridgeError> {
    addresses()?
        .login
        .clone()
        .send(FeedAuthCapabilityMsg { feed_id })
        .await?
}

pub async fn feed_auth_entry(feed_id: String) -> Result<Option<AuthEntryInfo>, BridgeError> {
    addresses()?
        .login
        .clone()
        .send(FeedAuthEntryMsg { feed_id })
        .await?
}

pub async fn feed_auth_submit_page(
    feed_id: String,
    current_url: String,
    response: String,
    response_headers: Vec<(String, String)>,
    cookies: Vec<CookieEntry>,
) -> Result<(), BridgeError> {
    addresses()?
        .login
        .clone()
        .send(FeedAuthSubmitPageMsg {
            feed_id,
            current_url,
            response,
            response_headers,
            cookies,
        })
        .await?
}

pub async fn feed_auth_status(feed_id: String) -> Result<AuthStatus, BridgeError> {
    addresses()?
        .login
        .clone()
        .send(FeedAuthStatusMsg { feed_id })
        .await?
}

pub async fn feed_auth_clear(feed_id: String) -> Result<(), BridgeError> {
    addresses()?
        .login
        .clone()
        .send(FeedAuthClearMsg { feed_id })
        .await?
}

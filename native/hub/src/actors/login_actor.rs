use std::path::{Path, PathBuf};
use std::sync::Arc;

use async_trait::async_trait;
use langhuan::auth::AuthStore;
use langhuan::cache::CachedFeed;
use langhuan::feed::{
    AuthPageContext, AuthStatus as FeedAuthStatus, CookieEntry as FeedCookieEntry, FeedAuthFlow,
};
use langhuan::script::lua::LuaFeed;
use messages::prelude::{Actor, Address, Context, Handler};

use crate::api::types::{AuthCapability, AuthEntryInfo, AuthStatus, BridgeError, CookieEntry};
use crate::localize_error;

use super::app_data_actor::InitializeAppDataDirectory;
use super::registry_actor::{GetFeed, GetFeedIds, RegistryActor};

// ---------------------------------------------------------------------------
// FRB-facing messages
// ---------------------------------------------------------------------------

pub struct FeedAuthCapabilityMsg {
    pub feed_id: String,
}

pub struct FeedAuthEntryMsg {
    pub feed_id: String,
}

pub struct FeedAuthSubmitPageMsg {
    pub feed_id: String,
    pub current_url: String,
    pub response: String,
    pub response_headers: Vec<(String, String)>,
    pub cookies: Vec<CookieEntry>,
}

pub struct FeedAuthStatusMsg {
    pub feed_id: String,
}

pub struct FeedAuthClearMsg {
    pub feed_id: String,
}

// ---------------------------------------------------------------------------
// Actor
// ---------------------------------------------------------------------------

pub struct LoginActor {
    registry_addr: Address<RegistryActor>,
    auth_dir: Option<PathBuf>,
    auth_store: Option<AuthStore>,
}

impl Actor for LoginActor {}

impl LoginActor {
    pub fn new(registry_addr: Address<RegistryActor>) -> Self {
        Self {
            registry_addr,
            auth_dir: None,
            auth_store: None,
        }
    }

    async fn initialize_app_data_directory(&mut self, path: &str) -> Result<(), String> {
        tracing::info!(path = %path, "initializing login actor storage");
        if self.auth_dir.is_some() {
            return Err(t!("error.registry_reload_not_supported").to_string());
        }

        let base_dir = Path::new(path);
        let auth_dir = base_dir.join("auth");

        tokio::fs::create_dir_all(&auth_dir)
            .await
            .map_err(|e| e.to_string())?;

        self.auth_store = Some(
            AuthStore::open(auth_dir.clone())
                .await
                .map_err(|e| localize_error(&e))?,
        );
        self.auth_dir = Some(auth_dir);

        self.hydrate_all_feeds().await?;
        tracing::info!("login actor storage initialized");
        Ok(())
    }

    async fn hydrate_all_feeds(&mut self) -> Result<(), String> {
        let feed_ids = match self.registry_addr.send(GetFeedIds).await {
            Ok(Ok(ids)) => ids,
            Ok(Err(err)) => return Err(err.to_string()),
            Err(err) => return Err(format!("internal error: {err}")),
        };

        for feed_id in feed_ids {
            let feed = self.resolve_feed(&feed_id).await?;
            self.hydrate_feed_auth(&feed_id, &feed).await?;
        }

        Ok(())
    }

    async fn resolve_feed(&mut self, feed_id: &str) -> Result<Arc<CachedFeed<LuaFeed>>, String> {
        match self
            .registry_addr
            .send(GetFeed {
                feed_id: feed_id.to_owned(),
            })
            .await
        {
            Ok(Ok(feed)) => Ok(feed),
            Ok(Err(err)) => Err(err.to_string()),
            Err(err) => Err(format!("internal error: {err}")),
        }
    }

    fn auth_store_mut(&mut self) -> Result<&mut AuthStore, BridgeError> {
        self.auth_store
            .as_mut()
            .ok_or_else(|| BridgeError::from(t!("error.app_data_dir_not_set").to_string()))
    }

    async fn hydrate_feed_auth(
        &self,
        feed_id: &str,
        feed: &CachedFeed<LuaFeed>,
    ) -> Result<(), String> {
        let Some(support) = feed.supports_auth() else {
            return Ok(());
        };

        let auth_store = self
            .auth_store
            .as_ref()
            .ok_or_else(|| t!("error.app_data_dir_not_set").to_string())?;
        let auth_info = auth_store
            .get_auth_info(feed_id)
            .await
            .map_err(|e| localize_error(&e))?;
        feed.set_auth_info(&support, auth_info)
            .map_err(|e| localize_error(&e))
    }

    async fn do_auth_capability(&mut self, feed_id: &str) -> Result<AuthCapability, BridgeError> {
        match self.resolve_feed(feed_id).await {
            Err(msg) => Err(BridgeError::from(msg)),
            Ok(feed) if feed.supports_auth().is_some() => Ok(AuthCapability::Supported),
            Ok(_) => Ok(AuthCapability::Unsupported),
        }
    }

    async fn do_auth_entry(&mut self, feed_id: &str) -> Result<Option<AuthEntryInfo>, BridgeError> {
        let feed = self.resolve_feed(feed_id).await?;
        let Some(support) = feed.supports_auth() else {
            return Ok(None);
        };
        match feed.auth_entry(&support) {
            Ok(entry) => Ok(Some(AuthEntryInfo {
                url: entry.url,
                title: entry.title,
            })),
            Err(e) => Err(BridgeError::from(e)),
        }
    }

    async fn do_auth_submit_page(&mut self, msg: FeedAuthSubmitPageMsg) -> Result<(), BridgeError> {
        let feed = self.resolve_feed(&msg.feed_id).await?;
        let Some(support) = feed.supports_auth() else {
            return Err(BridgeError::from(
                t!("error.auth_status_not_supported", feed_id = &msg.feed_id).to_string(),
            ));
        };
        let page = AuthPageContext {
            current_url: msg.current_url,
            response: msg.response.into(),
            response_headers: msg.response_headers,
            cookies: msg
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
        let auth_info = feed.parse_auth(&support, &page)?;
        let store = self.auth_store_mut()?;
        store.set_auth_info(&msg.feed_id, auth_info.clone()).await?;
        feed.set_auth_info(&support, Some(auth_info))
            .map_err(BridgeError::from)
    }

    async fn do_auth_status(&mut self, feed_id: &str) -> Result<AuthStatus, BridgeError> {
        let feed = self.resolve_feed(feed_id).await?;
        self.hydrate_feed_auth(feed_id, &feed).await?;
        let Some(support) = feed.supports_auth() else {
            return Err(BridgeError::from(
                t!("error.auth_status_not_supported", feed_id = feed_id).to_string(),
            ));
        };
        match feed.auth_status(&support).await {
            Ok(FeedAuthStatus::LoggedIn) => Ok(AuthStatus::LoggedIn),
            Ok(FeedAuthStatus::Expired) => Ok(AuthStatus::Expired),
            Ok(FeedAuthStatus::LoggedOut) => Ok(AuthStatus::LoggedOut),
            Err(e) => Err(BridgeError::from(e)),
        }
    }

    async fn do_auth_clear(&mut self, feed_id: &str) -> Result<(), BridgeError> {
        let feed = self.resolve_feed(feed_id).await?;
        let Some(support) = feed.supports_auth() else {
            return Ok(());
        };
        let store = self.auth_store_mut()?;
        store.clear_auth_info(feed_id).await?;
        feed.set_auth_info(&support, None)
            .map_err(BridgeError::from)
    }
}

// ---------------------------------------------------------------------------
// Handler impls
// ---------------------------------------------------------------------------

#[async_trait]
impl Handler<InitializeAppDataDirectory> for LoginActor {
    type Result = Result<(), String>;

    async fn handle(&mut self, msg: InitializeAppDataDirectory, _: &Context<Self>) -> Self::Result {
        self.initialize_app_data_directory(&msg.path).await
    }
}

#[async_trait]
impl Handler<FeedAuthCapabilityMsg> for LoginActor {
    type Result = Result<AuthCapability, BridgeError>;

    async fn handle(&mut self, msg: FeedAuthCapabilityMsg, _: &Context<Self>) -> Self::Result {
        self.do_auth_capability(&msg.feed_id).await
    }
}

#[async_trait]
impl Handler<FeedAuthEntryMsg> for LoginActor {
    type Result = Result<Option<AuthEntryInfo>, BridgeError>;

    async fn handle(&mut self, msg: FeedAuthEntryMsg, _: &Context<Self>) -> Self::Result {
        self.do_auth_entry(&msg.feed_id).await
    }
}

#[async_trait]
impl Handler<FeedAuthSubmitPageMsg> for LoginActor {
    type Result = Result<(), BridgeError>;

    async fn handle(&mut self, msg: FeedAuthSubmitPageMsg, _: &Context<Self>) -> Self::Result {
        self.do_auth_submit_page(msg).await
    }
}

#[async_trait]
impl Handler<FeedAuthStatusMsg> for LoginActor {
    type Result = Result<AuthStatus, BridgeError>;

    async fn handle(&mut self, msg: FeedAuthStatusMsg, _: &Context<Self>) -> Self::Result {
        self.do_auth_status(&msg.feed_id).await
    }
}

#[async_trait]
impl Handler<FeedAuthClearMsg> for LoginActor {
    type Result = Result<(), BridgeError>;

    async fn handle(&mut self, msg: FeedAuthClearMsg, _: &Context<Self>) -> Self::Result {
        self.do_auth_clear(&msg.feed_id).await
    }
}

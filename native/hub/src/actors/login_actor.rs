use std::sync::Arc;

use async_trait::async_trait;
use langhuan::cache::CachedFeed;
use langhuan::db::Db;
use langhuan::feed::{
    AuthPageContext, AuthStatus as FeedAuthStatus, CookieEntry as FeedCookieEntry, FeedAuthFlow,
};
use langhuan::script::lua::LuaFeed;
use messages::prelude::{Actor, Address, Context, Handler};

use crate::api::types::{
    AuthCapability, AuthEntryInfo, AuthStatus, BridgeError, CookieEntry, ErrorKind,
    ScriptExpectedReason,
};
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
    db: Option<Db>,
}

impl Actor for LoginActor {}

impl LoginActor {
    pub fn new(registry_addr: Address<RegistryActor>) -> Self {
        Self {
            registry_addr,
            db: None,
        }
    }

    async fn initialize_app_data_directory(&mut self, db: Db) -> Result<(), String> {
        tracing::info!("initializing login actor storage");
        if self.db.is_some() {
            return Err(t!("error.registry_reload_not_supported").to_string());
        }

        self.db = Some(db);
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

    fn db(&self) -> Result<&Db, BridgeError> {
        self.db
            .as_ref()
            .ok_or_else(|| BridgeError::from(t!("error.app_data_dir_not_set").to_string()))
    }

    /// Push the stored auth payload (if any) into a compiled feed.
    async fn hydrate_feed_auth(
        &self,
        feed_id: &str,
        feed: &CachedFeed<LuaFeed>,
    ) -> Result<(), String> {
        let Some(support) = feed.supports_auth() else {
            return Ok(());
        };

        let db = self
            .db
            .as_ref()
            .ok_or_else(|| t!("error.app_data_dir_not_set").to_string())?;
        let id = feed_id.to_owned();
        let auth_info = db
            .call(move |repo| repo.get_auth(&id))
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
        let db = self.db()?.clone();

        // Treat parsed auth as a candidate until the feed has verified it.
        // This keeps a failed login attempt from replacing a previously valid
        // session in memory or on disk.
        let id = msg.feed_id.clone();
        let stored_auth = db
            .call({
                let id = id.clone();
                move |repo| repo.get_auth(&id)
            })
            .await?;
        feed.set_auth_info(&support, Some(auth_info.clone()))
            .map_err(BridgeError::from)?;

        let verification = feed.auth_status(&support).await;
        match verification {
            Ok(FeedAuthStatus::LoggedIn) => {}
            Ok(FeedAuthStatus::Expired | FeedAuthStatus::LoggedOut) => {
                feed.set_auth_info(&support, stored_auth.clone())
                    .map_err(BridgeError::from)?;
                return Err(BridgeError {
                    kind: ErrorKind::ScriptExpected {
                        reason: ScriptExpectedReason::AuthRequired,
                    },
                    message: t!("error.auth_verification_failed").to_string(),
                });
            }
            Err(error) => {
                feed.set_auth_info(&support, stored_auth.clone())
                    .map_err(BridgeError::from)?;
                return Err(BridgeError::from(error));
            }
        }

        if let Err(error) = db
            .write(move |repo| repo.set_auth(&id, &auth_info, langhuan::db::now_ms()))
            .await
        {
            feed.set_auth_info(&support, stored_auth)
                .map_err(BridgeError::from)?;
            return Err(error.into());
        }
        Ok(())
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
        let db = self.db()?.clone();
        let id = feed_id.to_owned();
        db.write(move |repo| repo.clear_auth(&id)).await?;
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
        self.initialize_app_data_directory(msg.db).await
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

use std::path::{Path, PathBuf};
use std::sync::Arc;

use async_trait::async_trait;
use langhuan::auth::AuthStore;
use langhuan::cache::CachedFeed;
use langhuan::feed::{AuthPageContext, AuthStatus, CookieEntry as FeedCookieEntry, FeedAuthFlow};
use langhuan::script::lua::LuaFeed;
use messages::prelude::{Actor, Address, Context, Handler, Notifiable};
use rinf::{DartSignal, RustSignal};
use tokio::task::JoinSet;

use crate::localize_error;
use crate::signals::{
    FeedAuthCapabilityRequest, FeedAuthCapabilityResult, FeedAuthClearRequest, FeedAuthClearResult,
    FeedAuthEntryRequest, FeedAuthEntryResult, FeedAuthStatusRequest, FeedAuthStatusResult,
    FeedAuthSubmitPageRequest, FeedAuthSubmitPageResult,
};

use super::app_data_actor::InitializeAppDataDirectory;
use super::registry_actor::{GetFeed, GetFeedIds, RegistryActor};

/// Dedicated actor for feed auth/login responsibilities.
pub struct LoginActor {
    registry_addr: Address<RegistryActor>,
    auth_dir: Option<PathBuf>,
    auth_store: Option<AuthStore>,
    _owned_tasks: JoinSet<()>,
}

impl Actor for LoginActor {}

impl LoginActor {
    pub fn new(self_addr: Address<Self>, registry_addr: Address<RegistryActor>) -> Self {
        let mut _owned_tasks = JoinSet::new();
        _owned_tasks.spawn(Self::listen_to_auth_capability(self_addr.clone()));
        _owned_tasks.spawn(Self::listen_to_auth_entry(self_addr.clone()));
        _owned_tasks.spawn(Self::listen_to_auth_submit_page(self_addr.clone()));
        _owned_tasks.spawn(Self::listen_to_auth_status(self_addr.clone()));
        _owned_tasks.spawn(Self::listen_to_auth_clear(self_addr));

        Self {
            registry_addr,
            auth_dir: None,
            auth_store: None,
            _owned_tasks,
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

    fn auth_store(&self) -> Result<&AuthStore, String> {
        self.auth_store
            .as_ref()
            .ok_or_else(|| t!("error.app_data_dir_not_set").to_string())
    }

    fn auth_store_mut(&mut self) -> Result<&mut AuthStore, String> {
        self.auth_store
            .as_mut()
            .ok_or_else(|| t!("error.app_data_dir_not_set").to_string())
    }

    /// Resolve a feed, mapping any error through `err_fn` into an early-return
    /// value.  Callers write `let feed = self.resolve_feed_or(…).await?;`.
    async fn resolve_feed_or<R>(
        &mut self,
        feed_id: &str,
        err_fn: impl FnOnce(String) -> R,
    ) -> Result<Arc<CachedFeed<LuaFeed>>, R> {
        self.resolve_feed(feed_id).await.map_err(err_fn)
    }

    async fn hydrate_feed_auth(
        &self,
        feed_id: &str,
        feed: &CachedFeed<LuaFeed>,
    ) -> Result<(), String> {
        let Some(support) = feed.supports_auth() else {
            return Ok(());
        };

        let auth_store = self.auth_store()?;
        let auth_info = auth_store
            .get_auth_info(feed_id)
            .await
            .map_err(|e| localize_error(&e))?;
        feed.set_auth_info(&support, auth_info)
            .map_err(|e| localize_error(&e))
    }

    async fn do_auth_capability(
        &mut self,
        req: FeedAuthCapabilityRequest,
    ) -> FeedAuthCapabilityResult {
        let id = &req.request_id;
        match self.resolve_feed(&req.feed_id).await {
            Err(msg) => FeedAuthCapabilityResult::error(id, msg),
            Ok(feed) if feed.supports_auth().is_some() => FeedAuthCapabilityResult::supported(id),
            Ok(_) => FeedAuthCapabilityResult::unsupported(id),
        }
    }

    async fn do_auth_entry(&mut self, req: FeedAuthEntryRequest) -> FeedAuthEntryResult {
        let id = &req.request_id;
        let feed = match self
            .resolve_feed_or(&req.feed_id, |m| FeedAuthEntryResult::error(id, m))
            .await
        {
            Ok(f) => f,
            Err(r) => return r,
        };
        let Some(support) = feed.supports_auth() else {
            return FeedAuthEntryResult::unsupported(id);
        };
        match feed.auth_entry(&support) {
            Ok(entry) => FeedAuthEntryResult::success(id, entry.url, entry.title),
            Err(e) => FeedAuthEntryResult::error(id, localize_error(&e)),
        }
    }

    async fn do_auth_submit_page(
        &mut self,
        req: FeedAuthSubmitPageRequest,
    ) -> FeedAuthSubmitPageResult {
        let id = req.request_id.clone();
        let feed = match self
            .resolve_feed_or(&req.feed_id, |m| FeedAuthSubmitPageResult::error(&id, m))
            .await
        {
            Ok(f) => f,
            Err(r) => return r,
        };
        let Some(support) = feed.supports_auth() else {
            return FeedAuthSubmitPageResult::unsupported(&id);
        };
        let page = AuthPageContext {
            current_url: req.current_url,
            response: req.response.into(),
            response_headers: req.response_headers,
            cookies: req
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
        let auth_info = match feed.parse_auth(&support, &page) {
            Ok(a) => a,
            Err(e) => return FeedAuthSubmitPageResult::error(&id, localize_error(&e)),
        };
        let store = match self.auth_store_mut() {
            Ok(s) => s,
            Err(m) => return FeedAuthSubmitPageResult::error(&id, m),
        };
        if let Err(e) = store.set_auth_info(&req.feed_id, auth_info.clone()).await {
            return FeedAuthSubmitPageResult::error(&id, localize_error(&e));
        }
        match feed.set_auth_info(&support, Some(auth_info)) {
            Ok(()) => FeedAuthSubmitPageResult::success(&id),
            Err(e) => FeedAuthSubmitPageResult::error(&id, localize_error(&e)),
        }
    }

    async fn do_auth_status(&mut self, req: FeedAuthStatusRequest) -> FeedAuthStatusResult {
        let id = &req.request_id;
        let feed = match self
            .resolve_feed_or(&req.feed_id, |m| FeedAuthStatusResult::error(id, m))
            .await
        {
            Ok(f) => f,
            Err(r) => return r,
        };
        if let Err(m) = self.hydrate_feed_auth(&req.feed_id, &feed).await {
            return FeedAuthStatusResult::error(id, m);
        }
        let Some(support) = feed.supports_auth() else {
            return FeedAuthStatusResult::error(
                id,
                t!("error.auth_status_not_supported", feed_id = &req.feed_id).to_string(),
            );
        };
        match feed.auth_status(&support).await {
            Ok(AuthStatus::LoggedIn) => FeedAuthStatusResult::logged_in(id),
            Ok(AuthStatus::Expired) => FeedAuthStatusResult::expired(id),
            Ok(AuthStatus::LoggedOut) => FeedAuthStatusResult::logged_out(id),
            Err(e) => FeedAuthStatusResult::error(id, localize_error(&e)),
        }
    }

    async fn do_auth_clear(&mut self, req: FeedAuthClearRequest) -> FeedAuthClearResult {
        let id = req.request_id.clone();
        let feed = match self
            .resolve_feed_or(&req.feed_id, |m| FeedAuthClearResult::error(&id, m))
            .await
        {
            Ok(f) => f,
            Err(r) => return r,
        };
        let Some(support) = feed.supports_auth() else {
            return FeedAuthClearResult::success(&id);
        };
        let store = match self.auth_store_mut() {
            Ok(s) => s,
            Err(m) => return FeedAuthClearResult::error(&id, m),
        };
        if let Err(e) = store.clear_auth_info(&req.feed_id).await {
            return FeedAuthClearResult::error(&id, localize_error(&e));
        }
        match feed.set_auth_info(&support, None) {
            Ok(()) => FeedAuthClearResult::success(&id),
            Err(e) => FeedAuthClearResult::error(&id, localize_error(&e)),
        }
    }

    async fn listen_to_auth_capability(mut self_addr: Address<Self>) {
        let receiver = FeedAuthCapabilityRequest::get_dart_signal_receiver();
        while let Some(signal_pack) = receiver.recv().await {
            let _ = self_addr.notify(signal_pack.message).await;
        }
    }

    async fn listen_to_auth_entry(mut self_addr: Address<Self>) {
        let receiver = FeedAuthEntryRequest::get_dart_signal_receiver();
        while let Some(signal_pack) = receiver.recv().await {
            let _ = self_addr.notify(signal_pack.message).await;
        }
    }

    async fn listen_to_auth_submit_page(mut self_addr: Address<Self>) {
        let receiver = FeedAuthSubmitPageRequest::get_dart_signal_receiver();
        while let Some(signal_pack) = receiver.recv().await {
            let _ = self_addr.notify(signal_pack.message).await;
        }
    }

    async fn listen_to_auth_status(mut self_addr: Address<Self>) {
        let receiver = FeedAuthStatusRequest::get_dart_signal_receiver();
        while let Some(signal_pack) = receiver.recv().await {
            let _ = self_addr.notify(signal_pack.message).await;
        }
    }

    async fn listen_to_auth_clear(mut self_addr: Address<Self>) {
        let receiver = FeedAuthClearRequest::get_dart_signal_receiver();
        while let Some(signal_pack) = receiver.recv().await {
            let _ = self_addr.notify(signal_pack.message).await;
        }
    }
}

#[async_trait]
impl Handler<InitializeAppDataDirectory> for LoginActor {
    type Result = Result<(), String>;

    async fn handle(&mut self, msg: InitializeAppDataDirectory, _: &Context<Self>) -> Self::Result {
        self.initialize_app_data_directory(&msg.path).await
    }
}

#[async_trait]
impl Notifiable<FeedAuthCapabilityRequest> for LoginActor {
    async fn notify(&mut self, msg: FeedAuthCapabilityRequest, _: &Context<Self>) {
        tracing::debug!(request_id = %msg.request_id, feed_id = %msg.feed_id, "received auth capability request");
        self.do_auth_capability(msg).await.send_signal_to_dart();
    }
}

#[async_trait]
impl Notifiable<FeedAuthEntryRequest> for LoginActor {
    async fn notify(&mut self, msg: FeedAuthEntryRequest, _: &Context<Self>) {
        tracing::debug!(request_id = %msg.request_id, feed_id = %msg.feed_id, "received auth entry request");
        self.do_auth_entry(msg).await.send_signal_to_dart();
    }
}

#[async_trait]
impl Notifiable<FeedAuthSubmitPageRequest> for LoginActor {
    async fn notify(&mut self, msg: FeedAuthSubmitPageRequest, _: &Context<Self>) {
        tracing::debug!(request_id = %msg.request_id, feed_id = %msg.feed_id, "received auth submit page request");
        self.do_auth_submit_page(msg).await.send_signal_to_dart();
    }
}

#[async_trait]
impl Notifiable<FeedAuthStatusRequest> for LoginActor {
    async fn notify(&mut self, msg: FeedAuthStatusRequest, _: &Context<Self>) {
        tracing::debug!(request_id = %msg.request_id, feed_id = %msg.feed_id, "received auth status request");
        self.do_auth_status(msg).await.send_signal_to_dart();
    }
}

#[async_trait]
impl Notifiable<FeedAuthClearRequest> for LoginActor {
    async fn notify(&mut self, msg: FeedAuthClearRequest, _: &Context<Self>) {
        tracing::debug!(request_id = %msg.request_id, feed_id = %msg.feed_id, "received auth clear request");
        self.do_auth_clear(msg).await.send_signal_to_dart();
    }
}

#[cfg(test)]
mod tests {
    use std::error::Error;

    use langhuan::script::runtime::ScriptEngine;
    use messages::prelude::Context;

    use super::*;
    use crate::actors::registry_actor::RegistryActor;

    type TestResult = Result<(), Box<dyn Error>>;

    #[tokio::test]
    async fn initialize_app_data_directory_creates_auth_subdir() -> TestResult {
        let dir = tempfile::tempdir()?;

        let registry_context = Context::new();
        let registry_addr = registry_context.address();
        let login_context = Context::new();
        let login_addr = login_context.address();

        let registry_actor = RegistryActor::new(registry_addr.clone(), ScriptEngine::new());
        tokio::spawn(registry_context.run(registry_actor));

        let init_registry = registry_addr
            .clone()
            .send(InitializeAppDataDirectory {
                path: dir.path().to_string_lossy().to_string(),
            })
            .await;
        assert!(matches!(init_registry, Ok(Ok(_))));

        let mut login_actor = LoginActor::new(login_addr, registry_addr);
        let result = login_actor
            .initialize_app_data_directory(&dir.path().to_string_lossy())
            .await;

        assert!(result.is_ok());
        assert!(dir.path().join("auth").is_dir());
        Ok(())
    }
}

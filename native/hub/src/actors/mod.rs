//! This module contains actors.
//! To build a solid app, avoid communicating by sharing memory.
//! Focus on message passing instead.

pub(crate) mod app_data_actor;
pub(crate) mod bookmark_actor;
pub(crate) mod bookshelf_actor;
pub(crate) mod conversion_actor;
pub(crate) mod feed_actor;
pub(crate) mod locale_actor;
pub(crate) mod login_actor;
pub(crate) mod reading_progress_actor;
pub(crate) mod registry_actor;
pub(crate) mod webview_actor;

pub(crate) use app_data_actor::AppDataActor;
pub(crate) use bookmark_actor::BookmarkActor;
pub(crate) use bookshelf_actor::BookshelfActor;
pub(crate) use conversion_actor::ConversionActor;
pub(crate) use feed_actor::FeedActor;
use langhuan::script::runtime::ScriptEngine;
pub(crate) use locale_actor::LocaleActor;
pub(crate) use login_actor::LoginActor;
use messages::prelude::{Address, Context};
pub(crate) use reading_progress_actor::ReadingProgressActor;
pub(crate) use registry_actor::RegistryActor;
use tokio::spawn;
use tokio::sync::OnceCell;
pub(crate) use webview_actor::WebviewActor;

// Uncomment below to target the web.
// use tokio_with_wasm::alias as tokio;

/// Global actor addresses, initialised once by [`create_actors`].
static ACTOR_ADDRESSES: OnceCell<ActorAddresses> = OnceCell::const_new();

/// Global handle to the application database, set once the app-data
/// directory has been initialized.
///
/// The api layer (covers, cache stats, maintenance) reads through this
/// handle instead of round-tripping through an actor, since these are
/// one-shot queries over cloned [`Db`] handles — the actor tree keeps the
/// mutable state.
static HUB_DB: OnceCell<langhuan::db::Db> = OnceCell::const_new();

/// Holds addresses for every actor in the system.
pub(crate) struct ActorAddresses {
    pub registry: Address<RegistryActor>,
    pub bookshelf: Address<BookshelfActor>,
    pub feed: Address<FeedActor>,
    pub login: Address<LoginActor>,
    pub reading_progress: Address<ReadingProgressActor>,
    pub locale: Address<LocaleActor>,
    pub app_data: Address<AppDataActor>,
    pub bookmark: Address<BookmarkActor>,
    pub conversion: Address<ConversionActor>,
    pub webview: Address<WebviewActor>,
}

/// Returns a reference to the global actor addresses.
///
/// Returns an error if called before [`create_actors`] has completed.
pub(crate) fn addresses() -> Result<&'static ActorAddresses, crate::api::types::BridgeError> {
    ACTOR_ADDRESSES.get().ok_or_else(|| {
        crate::api::types::BridgeError::from(
            "actors not yet initialised — call create_actors() first".to_owned(),
        )
    })
}

/// Publish the global database handle (called by the app-data actor after a
/// successful initialization). Fails when a database is already published.
pub(crate) fn set_hub_db(db: langhuan::db::Db) -> Result<(), ()> {
    HUB_DB.set(db).map_err(|_| ())
}

/// The global database handle, once the app-data directory is initialized.
pub(crate) fn hub_db() -> Result<langhuan::db::Db, crate::api::types::BridgeError> {
    HUB_DB.get().cloned().ok_or_else(|| {
        crate::api::types::BridgeError::from(
            rust_i18n::t!("error.app_data_dir_not_set").to_string(),
        )
    })
}

/// Creates and spawns the actors in the async system.
pub async fn create_actors() {
    if addresses().is_ok() {
        tracing::warn!("create_actors called more than once — ignoring");
        return;
    }
    tracing::debug!("creating locale actor");
    let locale_context = Context::new();
    let locale_addr = locale_context.address();
    let locale_actor = LocaleActor::new();
    spawn(locale_context.run(locale_actor));

    let engine = ScriptEngine::new();
    tracing::debug!("script engine initialized");

    // RegistryActor — owns the script registry and handles feed management.
    tracing::debug!("creating registry actor");
    let registry_context = Context::new();
    let registry_addr = registry_context.address();

    tracing::debug!("creating app data actor");
    let app_data_context = Context::new();
    let app_data_addr = app_data_context.address();

    tracing::debug!("creating login actor");
    let login_context = Context::new();
    let login_addr = login_context.address();

    tracing::debug!("creating webview actor");
    let webview_context = Context::new();
    let webview_addr = webview_context.address();

    // BookshelfActor - local bookshelf storage and simple capability response.
    tracing::debug!("creating bookshelf actor");
    let bookshelf_context = Context::new();
    let bookshelf_addr = bookshelf_context.address();

    tracing::debug!("creating reading progress actor");
    let reading_progress_context = Context::new();
    let reading_progress_addr = reading_progress_context.address();

    tracing::debug!("creating bookmark actor");
    let bookmark_context = Context::new();
    let bookmark_addr = bookmark_context.address();

    let registry_actor = RegistryActor::new(engine, webview_addr.clone());
    let login_actor = LoginActor::new(registry_addr.clone());
    let app_data_actor = AppDataActor::new(
        registry_addr.clone(),
        login_addr.clone(),
        bookshelf_addr.clone(),
        reading_progress_addr.clone(),
        bookmark_addr.clone(),
    );
    let reading_progress_actor = ReadingProgressActor::new();
    let bookmark_actor = BookmarkActor::new();
    let webview_actor = WebviewActor::new();
    spawn(registry_context.run(registry_actor));
    spawn(login_context.run(login_actor));
    spawn(app_data_context.run(app_data_actor));
    spawn(reading_progress_context.run(reading_progress_actor));
    spawn(bookmark_context.run(bookmark_actor));
    spawn(webview_context.run(webview_actor));

    // ConversionActor — holds the current Chinese conversion mode and
    // produces FilterChain instances for FeedActor.
    tracing::debug!("creating conversion actor");
    let conversion_context = Context::new();
    let conversion_addr = conversion_context.address();
    let conversion_actor = ConversionActor::new();
    spawn(conversion_context.run(conversion_actor));

    // FeedActor — handles feed content streaming, resolves feeds via
    // Handler<GetFeed> on the RegistryActor.
    tracing::debug!("creating feed actor");
    let feed_context = Context::new();
    let feed_addr = feed_context.address();
    let feed_actor = FeedActor::new(registry_addr.clone(), conversion_addr.clone());
    spawn(feed_context.run(feed_actor));

    let bookshelf_actor = BookshelfActor::new();
    spawn(bookshelf_context.run(bookshelf_actor));

    if ACTOR_ADDRESSES
        .set(ActorAddresses {
            registry: registry_addr,
            bookshelf: bookshelf_addr,
            feed: feed_addr,
            login: login_addr,
            reading_progress: reading_progress_addr,
            locale: locale_addr,
            app_data: app_data_addr,
            bookmark: bookmark_addr,
            conversion: conversion_addr,
            webview: webview_addr,
        })
        .is_err()
    {
        panic!("create_actors called more than once");
    }

    tracing::info!("all actors spawned");
}

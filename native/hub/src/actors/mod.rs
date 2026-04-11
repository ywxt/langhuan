//! This module contains actors.
//! To build a solid app, avoid communicating by sharing memory.
//! Focus on message passing instead.

pub(crate) mod app_data_actor;
pub(crate) mod bookshelf_actor;
pub(crate) mod locale_actor;
pub(crate) mod login_actor;
pub(crate) mod reading_progress_actor;
pub(crate) mod registry_actor;
pub(crate) mod stream_actor;

pub(crate) use app_data_actor::AppDataActor;
pub(crate) use bookshelf_actor::BookshelfActor;
use langhuan::script::runtime::ScriptEngine;
pub(crate) use locale_actor::LocaleActor;
pub(crate) use login_actor::LoginActor;
use messages::prelude::{Address, Context};
pub(crate) use reading_progress_actor::ReadingProgressActor;
pub(crate) use registry_actor::RegistryActor;
pub(crate) use stream_actor::StreamActor;
use tokio::spawn;
use tokio::sync::OnceCell;

// Uncomment below to target the web.
// use tokio_with_wasm::alias as tokio;

/// Global actor addresses, initialised once by [`create_actors`].
static ACTOR_ADDRESSES: OnceCell<ActorAddresses> = OnceCell::const_new();

/// Holds addresses for every actor in the system.
pub(crate) struct ActorAddresses {
    pub registry: Address<RegistryActor>,
    pub bookshelf: Address<BookshelfActor>,
    pub stream: Address<StreamActor>,
    pub login: Address<LoginActor>,
    pub reading_progress: Address<ReadingProgressActor>,
    pub locale: Address<LocaleActor>,
    pub app_data: Address<AppDataActor>,
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

    // BookshelfActor - local bookshelf storage and simple capability response.
    tracing::debug!("creating bookshelf actor");
    let bookshelf_context = Context::new();
    let bookshelf_addr = bookshelf_context.address();

    tracing::debug!("creating reading progress actor");
    let reading_progress_context = Context::new();
    let reading_progress_addr = reading_progress_context.address();

    let registry_actor = RegistryActor::new(registry_addr.clone(), engine);
    let login_actor = LoginActor::new(registry_addr.clone());
    let app_data_actor = AppDataActor::new(
        registry_addr.clone(),
        login_addr.clone(),
        bookshelf_addr.clone(),
        reading_progress_addr.clone(),
    );
    let reading_progress_actor = ReadingProgressActor::new();
    spawn(registry_context.run(registry_actor));
    spawn(login_context.run(login_actor));
    spawn(app_data_context.run(app_data_actor));
    spawn(reading_progress_context.run(reading_progress_actor));

    // StreamActor — handles feed content streaming, resolves feeds via
    // Handler<GetFeed> on the RegistryActor.
    tracing::debug!("creating stream actor");
    let stream_context = Context::new();
    let stream_addr = stream_context.address();
    let stream_actor = StreamActor::new(registry_addr.clone());
    spawn(stream_context.run(stream_actor));

    let bookshelf_actor = BookshelfActor::new(registry_addr.clone());
    spawn(bookshelf_context.run(bookshelf_actor));

    if ACTOR_ADDRESSES
        .set(ActorAddresses {
            registry: registry_addr,
            bookshelf: bookshelf_addr,
            stream: stream_addr,
            login: login_addr,
            reading_progress: reading_progress_addr,
            locale: locale_addr,
            app_data: app_data_addr,
        })
        .is_err()
    {
        panic!("create_actors called more than once");
    }

    tracing::info!("all actors spawned");
}

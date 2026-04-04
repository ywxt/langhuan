//! This module contains actors.
//! To build a solid app, avoid communicating by sharing memory.
//! Focus on message passing instead.

mod app_data_actor;
mod bookshelf_actor;
mod locale_actor;
mod registry_actor;
mod stream_actor;

use app_data_actor::AppDataActor;
use bookshelf_actor::BookshelfActor;
use langhuan::script::runtime::ScriptEngine;
use locale_actor::LocaleActor;
use messages::prelude::Context;
use registry_actor::RegistryActor;
use stream_actor::StreamActor;
use tokio::spawn;

// Uncomment below to target the web.
// use tokio_with_wasm::alias as tokio;

/// Creates and spawns the actors in the async system.
pub async fn create_actors() {
    tracing::debug!("creating locale actor");
    let locale_context = Context::new();
    let locale_addr = locale_context.address();
    let locale_actor = LocaleActor::new(locale_addr.clone());
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

    // BookshelfActor - local bookshelf storage and simple capability response.
    tracing::debug!("creating bookshelf actor");
    let bookshelf_context = Context::new();
    let bookshelf_addr = bookshelf_context.address();

    let registry_actor = RegistryActor::new(registry_addr.clone(), engine);
    let app_data_actor = AppDataActor::new(app_data_addr, registry_addr.clone(), bookshelf_addr.clone());
    spawn(registry_context.run(registry_actor));
    spawn(app_data_context.run(app_data_actor));

    // StreamActor — handles feed content streaming, resolves feeds via
    // Handler<GetFeed> on the RegistryActor.
    tracing::debug!("creating stream actor");
    let stream_context = Context::new();
    let stream_addr = stream_context.address();
    let stream_actor = StreamActor::new(stream_addr, registry_addr.clone());
    spawn(stream_context.run(stream_actor));

    let bookshelf_actor = BookshelfActor::new(bookshelf_addr, registry_addr);
    spawn(bookshelf_context.run(bookshelf_actor));

    tracing::info!("all actors spawned");
}

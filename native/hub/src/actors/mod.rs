//! This module contains actors.
//! To build a solid app, avoid communicating by sharing memory.
//! Focus on message passing instead.

mod locale_actor;
mod registry_actor;
mod stream_actor;

use langhuan::script::engine::ScriptEngine;
use locale_actor::LocaleActor;
use messages::prelude::Context;
use registry_actor::RegistryActor;
use stream_actor::StreamActor;
use tokio::spawn;

// Uncomment below to target the web.
// use tokio_with_wasm::alias as tokio;

/// Creates and spawns the actors in the async system.
pub async fn create_actors() {
    let locale_context = Context::new();
    let locale_addr = locale_context.address();
    let locale_actor = LocaleActor::new(locale_addr.clone());
    spawn(locale_context.run(locale_actor));

    let engine = ScriptEngine::new();

    // RegistryActor — owns the script registry and handles feed management.
    let registry_context = Context::new();
    let registry_addr = registry_context.address();
    let registry_actor = RegistryActor::new(registry_addr.clone(), engine);
    spawn(registry_context.run(registry_actor));

    // StreamActor — handles feed content streaming, resolves feeds via
    // Handler<GetFeed> on the RegistryActor.
    let stream_context = Context::new();
    let stream_addr = stream_context.address();
    let stream_actor = StreamActor::new(stream_addr, registry_addr);
    spawn(stream_context.run(stream_actor));
}

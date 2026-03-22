//! This module contains actors.
//! To build a solid app, avoid communicating by sharing memory.
//! Focus on message passing instead.

mod feed_actor;
mod first;
mod second;

use feed_actor::FeedActor;
use first::FirstActor;
use langhuan::script::engine::ScriptEngine;
use messages::prelude::Context;
use rinf::DartSignal;
use second::SecondActor;
use tokio::spawn;

use crate::signals::{
    ChapterContentRequest, ChaptersRequest, FeedCancelRequest, ListFeedsRequest, SearchRequest,
    SetScriptDirectory,
};

// Uncomment below to target the web.
// use tokio_with_wasm::alias as tokio;

/// Creates and spawns the actors in the async system.
pub async fn create_actors() {
    // Though simple async tasks work, using the actor model
    // is highly recommended for state management
    // to achieve modularity and scalability in your app.
    // Actors keep ownership of their state and run in their own loops,
    // handling messages from other actors or external sources,
    // such as websockets or timers.

    // Create actor contexts.
    let first_context = Context::new();
    let first_addr = first_context.address();
    let second_context = Context::new();

    // Spawn the actors.
    let first_actor = FirstActor::new(first_addr.clone());
    spawn(first_context.run(first_actor));
    let second_actor = SecondActor::new(first_addr);
    spawn(second_context.run(second_actor));

    // Spawn the FeedActor event loop.
    spawn(run_feed_actor());
}

/// Run the FeedActor's signal-listening loop.
///
/// Listens for all four feed-related Dart signals and dispatches them to the
/// actor.  Cleanup of finished tasks is performed on every iteration.
async fn run_feed_actor() {
    let engine = ScriptEngine::new();
    let mut actor = FeedActor::new(engine);

    let search_rx = SearchRequest::get_dart_signal_receiver();
    let chapters_rx = ChaptersRequest::get_dart_signal_receiver();
    let chapter_content_rx = ChapterContentRequest::get_dart_signal_receiver();
    let cancel_rx = FeedCancelRequest::get_dart_signal_receiver();
    let set_dir_rx = SetScriptDirectory::get_dart_signal_receiver();
    let list_feeds_rx = ListFeedsRequest::get_dart_signal_receiver();

    loop {
        tokio::select! {
            Some(pack) = search_rx.recv() => {
                actor.handle_search(pack.message).await;
            }
            Some(pack) = chapters_rx.recv() => {
                actor.handle_chapters(pack.message).await;
            }
            Some(pack) = chapter_content_rx.recv() => {
                actor.handle_chapter_content(pack.message).await;
            }
            Some(pack) = cancel_rx.recv() => {
                actor.handle_cancel(pack.message);
            }
            Some(pack) = set_dir_rx.recv() => {
                actor.handle_set_directory(pack.message).await;
            }
            Some(pack) = list_feeds_rx.recv() => {
                actor.handle_list_feeds(pack.message);
            }
        }
        actor.cleanup_finished();
    }
}


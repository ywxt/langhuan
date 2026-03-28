//! This module contains actors.
//! To build a solid app, avoid communicating by sharing memory.
//! Focus on message passing instead.

mod feed_actor;

use feed_actor::FeedActor;
use langhuan::script::engine::ScriptEngine;
use messages::prelude::Context;
use rinf::DartSignal;
use tokio::spawn;

use crate::signals::{
    ChapterContentRequest, ChaptersRequest, FeedCancelRequest, InstallFeedRequest,
    ListFeedsRequest, PreviewFeedFromFile, PreviewFeedFromUrl, RemoveFeedRequest,
    SearchRequest, SetScriptDirectory,
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
    let preview_url_rx = PreviewFeedFromUrl::get_dart_signal_receiver();
    let preview_file_rx = PreviewFeedFromFile::get_dart_signal_receiver();
    let install_rx = InstallFeedRequest::get_dart_signal_receiver();
    let remove_rx = RemoveFeedRequest::get_dart_signal_receiver();

    loop {
        tokio::select! {
            Some(pack) = search_rx.recv() => {
                actor.handle_search(pack.message);
            }
            Some(pack) = chapters_rx.recv() => {
                actor.handle_chapters(pack.message);
            }
            Some(pack) = chapter_content_rx.recv() => {
                actor.handle_chapter_content(pack.message);
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
            Some(pack) = preview_url_rx.recv() => {
                actor.handle_preview_from_url(pack.message).await;
            }
            Some(pack) = preview_file_rx.recv() => {
                actor.handle_preview_from_file(pack.message).await;
            }
            Some(pack) = install_rx.recv() => {
                actor.handle_install(pack.message).await;
            }
            Some(pack) = remove_rx.recv() => {
                actor.handle_remove(pack.message).await;
            }
        }
        actor.cleanup_finished();
    }
}


use super::types::{BridgeError, FeedMetaItem, FeedPreviewInfo};
use crate::actors::{
    addresses,
    registry_actor::{
        InstallFeed, ListFeeds, PreviewFeedFromFile, PreviewFeedFromUrl, RemoveFeed, SetFeedEnabled,
    },
};

pub async fn list_feeds() -> Result<Vec<FeedMetaItem>, BridgeError> {
    let items = addresses()?.registry.clone().send(ListFeeds).await?;
    Ok(items)
}

pub async fn preview_feed_from_url(url: String) -> Result<FeedPreviewInfo, BridgeError> {
    addresses()?
        .registry
        .clone()
        .send(PreviewFeedFromUrl { url })
        .await?
}

pub async fn preview_feed_from_file(path: String) -> Result<FeedPreviewInfo, BridgeError> {
    addresses()?
        .registry
        .clone()
        .send(PreviewFeedFromFile { path })
        .await?
}

pub async fn install_feed(request_id: String) -> Result<(), BridgeError> {
    addresses()?
        .registry
        .clone()
        .send(InstallFeed { request_id })
        .await?
}

pub async fn remove_feed(feed_id: String) -> Result<(), BridgeError> {
    addresses()?
        .registry
        .clone()
        .send(RemoveFeed { feed_id })
        .await?
}

/// Pause (`enabled = false`) or resume a feed. A paused feed is excluded
/// from aggregated search and bookshelf update checks; its shelf, progress
/// and cache stay intact, and explicit single-feed actions keep working.
pub async fn set_feed_enabled(feed_id: String, enabled: bool) -> Result<(), BridgeError> {
    addresses()?
        .registry
        .clone()
        .send(SetFeedEnabled { feed_id, enabled })
        .await?
}

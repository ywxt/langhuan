use super::types::{BridgeError, FeedMetaItem, FeedPreviewInfo};
use crate::actors::{
    addresses,
    registry_actor::{InstallFeed, ListFeeds, PreviewFeedFromFile, PreviewFeedFromUrl, RemoveFeed},
};

pub async fn list_feeds() -> Result<Vec<FeedMetaItem>, BridgeError> {
    let items = addresses()?
        .registry
        .clone()
        .send(ListFeeds)
        .await?;
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

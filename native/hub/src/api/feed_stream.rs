use crate::actors::addresses;
use crate::actors::feed_actor::{
    GetBookInfo, GetChapters, GetParagraphs, OpenAggregatedSearchStream, OpenSearchStream,
    PullStream,
};

use super::types::BookInfo;
pub use super::types::{
    AggregatedSearchEvent, BridgeError, ChapterItem, ParagraphContent, SearchResultItem,
};

// ---------------------------------------------------------------------------
// Pull-based stream types (opaque to Dart via FRB)
// ---------------------------------------------------------------------------

/// A pull-based stream of search results.
pub struct FeedSearchStream(PullStream<SearchResultItem>);

impl FeedSearchStream {
    pub async fn next(&mut self) -> Result<Option<SearchResultItem>, BridgeError> {
        self.0.next().await
    }

    pub fn cancel(&mut self) {
        self.0.cancel();
    }
}

/// A pull-based stream of aggregated search events across all feeds.
pub struct AggregatedSearchStream(PullStream<AggregatedSearchEvent>);

impl AggregatedSearchStream {
    pub async fn next(&mut self) -> Result<Option<AggregatedSearchEvent>, BridgeError> {
        self.0.next().await
    }

    pub fn cancel(&mut self) {
        self.0.cancel();
    }
}

// ---------------------------------------------------------------------------
// Factory functions (FRB API surface)
// ---------------------------------------------------------------------------

/// Open a pull-based search stream.
pub async fn open_search_stream(
    feed_id: String,
    keyword: String,
) -> Result<FeedSearchStream, BridgeError> {
    let stream = addresses()?
        .feed
        .clone()
        .send(OpenSearchStream { feed_id, keyword })
        .await??;
    Ok(FeedSearchStream(stream))
}

/// Open a pull-based search stream across every installed feed. Results
/// arrive interleaved, each attributed to its source; a failing source
/// yields a [`AggregatedSearchEvent::FeedError`] event instead of ending
/// the stream.
pub async fn open_aggregated_search_stream(
    keyword: String,
) -> Result<AggregatedSearchStream, BridgeError> {
    let stream = addresses()?
        .feed
        .clone()
        .send(OpenAggregatedSearchStream { keyword })
        .await??;
    Ok(AggregatedSearchStream(stream))
}

/// Fetch a complete chapter list in one bridge call.
///
/// Reader startup needs the whole list before it can restore a saved
/// position. The actor collects it in one background task, avoiding both
/// per-item channels and per-item Dart/Rust bridge round-trips.
pub async fn chapters(
    feed_id: String,
    book_id: String,
    force_refresh: bool,
) -> Result<Vec<ChapterItem>, BridgeError> {
    let task = addresses()?
        .feed
        .clone()
        .send(GetChapters {
            feed_id,
            book_id,
            force_refresh,
        })
        .await??;
    task.resolve().await
}

/// Fetch one complete chapter in one bridge call.
///
/// A reader page cannot paginate until all paragraphs are available, so
/// crossing the bridge once is substantially cheaper than pulling every
/// paragraph separately, especially on cache hits.
pub async fn paragraphs(
    feed_id: String,
    book_id: String,
    chapter_id: String,
    force_refresh: bool,
) -> Result<Vec<ParagraphContent>, BridgeError> {
    let task = addresses()?
        .feed
        .clone()
        .send(GetParagraphs {
            feed_id,
            book_id,
            chapter_id,
            force_refresh,
        })
        .await??;
    task.resolve().await
}

/// Fetch book info (single value, not a stream).
pub async fn book_info(
    feed_id: String,
    book_id: String,
    force_refresh: bool,
) -> Result<BookInfo, BridgeError> {
    addresses()?
        .feed
        .clone()
        .send(GetBookInfo {
            feed_id,
            book_id,
            force_refresh,
        })
        .await?
}

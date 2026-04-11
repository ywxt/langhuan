use crate::actors::stream_actor::{
    GetBookInfo, OpenChaptersStream, OpenParagraphsStream, OpenSearchStream, PullStream,
};
use crate::actors::addresses;

use super::types::BookInfo;
pub use super::types::{BridgeError, ChapterItem, ParagraphContent, SearchResultItem};

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

/// A pull-based stream of chapter items.
pub struct FeedChaptersStream(PullStream<ChapterItem>);

impl FeedChaptersStream {
    pub async fn next(&mut self) -> Result<Option<ChapterItem>, BridgeError> {
        self.0.next().await
    }

    pub fn cancel(&mut self) {
        self.0.cancel();
    }
}

/// A pull-based stream of paragraph content.
pub struct FeedParagraphsStream(PullStream<ParagraphContent>);

impl FeedParagraphsStream {
    pub async fn next(&mut self) -> Result<Option<ParagraphContent>, BridgeError> {
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
        .stream
        .clone()
        .send(OpenSearchStream { feed_id, keyword })
        .await??;
    Ok(FeedSearchStream(stream))
}

/// Open a pull-based chapters stream.
pub async fn open_chapters_stream(
    feed_id: String,
    book_id: String,
) -> Result<FeedChaptersStream, BridgeError> {
    let stream = addresses()?
        .stream
        .clone()
        .send(OpenChaptersStream { feed_id, book_id })
        .await??;
    Ok(FeedChaptersStream(stream))
}

/// Open a pull-based paragraphs stream.
pub async fn open_paragraphs_stream(
    feed_id: String,
    book_id: String,
    chapter_id: String,
) -> Result<FeedParagraphsStream, BridgeError> {
    let stream = addresses()?
        .stream
        .clone()
        .send(OpenParagraphsStream {
            feed_id,
            book_id,
            chapter_id,
        })
        .await??;
    Ok(FeedParagraphsStream(stream))
}

/// Fetch book info (single value, not a stream).
pub async fn book_info(feed_id: String, book_id: String) -> Result<BookInfo, BridgeError> {
    addresses()?
        .stream
        .clone()
        .send(GetBookInfo { feed_id, book_id })
        .await?
}

use std::pin::Pin;

use tokio_stream::Stream;

use crate::error::Result;
use crate::model::{BookInfo, ChapterContent, ChapterInfo, SearchResult};
use crate::script::meta::FeedMeta;

/// A pinned, boxed, `Send`-able stream of `Result<T>`.
pub type FeedStream<'a, T> = Pin<Box<dyn Stream<Item = Result<T>> + Send + 'a>>;

/// A book feed (書源) that can search for books, retrieve book information,
/// list chapters, and fetch chapter content.
///
/// The paginated methods (`search`, `chapters`, `chapter_content`) return a
/// [`FeedStream`] that automatically fetches all pages and yields individual
/// items one by one.  Callers do not need to manage cursors — pagination is
/// entirely internal.
///
/// On a transient error the stream retries the failing page up to the
/// implementation-defined maximum before yielding the error and terminating.
pub trait Feed: Send + Sync {
    /// Search for books matching the given keyword.
    ///
    /// Returns a stream that yields each [`SearchResult`] as it is received,
    /// automatically following pagination until all results are exhausted.
    fn search<'a>(&'a self, keyword: &'a str) -> FeedStream<'a, SearchResult>;

    /// Retrieve detailed information about a book by its ID.
    fn book_info(&self, id: &str) -> impl Future<Output = Result<BookInfo>> + Send;

    /// List chapters (table of contents) for a book.
    ///
    /// Returns a stream that yields each [`ChapterInfo`] as it is received,
    /// automatically following pagination.
    fn chapters<'a>(&'a self, book_id: &'a str) -> FeedStream<'a, ChapterInfo>;

    /// Fetch the textual content of a chapter.
    ///
    /// Returns a stream that yields each [`ChapterContent`] segment as it is
    /// received, automatically following pagination.
    fn chapter_content<'a>(&'a self, chapter_id: &'a str) -> FeedStream<'a, ChapterContent>;

    /// The metadata of this feed (id, name, version, etc.).
    fn meta(&self) -> &FeedMeta;
}

use crate::error::Result;
use crate::model::{BookInfo, ChapterContent, ChapterInfo, Page, SearchResult};
use crate::script::meta::FeedMeta;

/// A book feed (書源) that can search for books, retrieve book information,
/// list chapters, and fetch chapter content.
///
/// The associated type `Cursor` is opaque and determined by the implementation.
/// For paginated methods:
/// - `None` requests the first page.
/// - `Some(cursor)` requests the page identified by the cursor returned from
///   the previous call's [`Page::next_cursor`].
pub trait Feed: Send + Sync {
    /// The cursor type used for pagination. Can be a simple `String`, an
    /// `mlua::Value`, or any other type that suits the implementation.
    type Cursor: Send + Sync;

    /// Search for books matching the given keyword.
    fn search(
        &self,
        keyword: &str,
        cursor: Option<&Self::Cursor>,
    ) -> impl Future<Output = Result<Page<SearchResult, Self::Cursor>>> + Send;

    /// Retrieve detailed information about a book by its ID.
    fn book_info(&self, id: &str) -> impl Future<Output = Result<BookInfo>> + Send;

    /// List chapters (table of contents) for a book.
    fn chapters(
        &self,
        book_id: &str,
        cursor: Option<&Self::Cursor>,
    ) -> impl Future<Output = Result<Page<ChapterInfo, Self::Cursor>>> + Send;

    /// Fetch the textual content of a chapter.
    fn chapter_content(
        &self,
        chapter_id: &str,
        cursor: Option<&Self::Cursor>,
    ) -> impl Future<Output = Result<Page<ChapterContent, Self::Cursor>>> + Send;

    /// The metadata of this feed (id, name, version, etc.).
    fn meta(&self) -> &FeedMeta;
}

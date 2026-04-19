use crate::actors::addresses;
use crate::actors::bookmark_actor::{AddBookmark, ListBookmarks, RemoveBookmark};
use crate::api::types::{BookmarkItem, BridgeError, ParagraphId};

/// Add a bookmark for the current reading position.
pub async fn add_bookmark(
    feed_id: String,
    book_id: String,
    chapter_id: String,
    paragraph_id: ParagraphId,
    paragraph_name: String,
    paragraph_preview: String,
    label: String,
) -> Result<BookmarkItem, BridgeError> {
    addresses()?
        .bookmark
        .clone()
        .send(AddBookmark {
            feed_id,
            book_id,
            chapter_id,
            paragraph_id: paragraph_id.to_string_lossy(),
            paragraph_name,
            paragraph_preview,
            label,
        })
        .await?
}

/// Remove a bookmark by its id. Returns true if removed.
pub async fn remove_bookmark(id: String) -> Result<bool, BridgeError> {
    addresses()?
        .bookmark
        .clone()
        .send(RemoveBookmark { id })
        .await?
}

/// List all bookmarks for a book.
pub async fn list_bookmarks(
    feed_id: String,
    book_id: String,
) -> Result<Vec<BookmarkItem>, BridgeError> {
    addresses()?
        .bookmark
        .clone()
        .send(ListBookmarks { feed_id, book_id })
        .await?
}

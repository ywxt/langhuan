use super::types::{BookshelfAddOutcome, BookshelfListItem, BookshelfRemoveOutcome, BridgeError};
use crate::actors::{
    addresses,
    bookshelf_actor::{BookshelfAdd, BookshelfList, BookshelfRemove},
};

/// Add a book to the bookshelf.
///
/// The display snapshot (title/author/cover/description) is taken from the
/// search result or detail page the user is looking at, so the shelf renders
/// instantly even before the book info is (re-)fetched.
#[allow(clippy::too_many_arguments)]
pub async fn bookshelf_add(
    feed_id: String,
    source_book_id: String,
    title: String,
    author: String,
    cover_url: Option<String>,
    description: Option<String>,
) -> Result<BookshelfAddOutcome, BridgeError> {
    addresses()?
        .bookshelf
        .clone()
        .send(BookshelfAdd {
            feed_id,
            source_book_id,
            title,
            author,
            cover_url,
            description,
        })
        .await?
}

pub async fn bookshelf_remove(
    feed_id: String,
    source_book_id: String,
) -> Result<BookshelfRemoveOutcome, BridgeError> {
    addresses()?
        .bookshelf
        .clone()
        .send(BookshelfRemove {
            feed_id,
            source_book_id,
        })
        .await?
}

pub async fn bookshelf_list() -> Result<Vec<BookshelfListItem>, BridgeError> {
    addresses()?.bookshelf.clone().send(BookshelfList).await?
}

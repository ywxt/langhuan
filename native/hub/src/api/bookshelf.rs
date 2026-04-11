use super::types::{BookshelfAddOutcome, BookshelfListItem, BookshelfRemoveOutcome, BridgeError};
use crate::actors::{
    addresses,
    bookshelf_actor::{BookshelfAdd, BookshelfList, BookshelfRemove},
};

pub async fn bookshelf_add(
    feed_id: String,
    source_book_id: String,
) -> Result<BookshelfAddOutcome, BridgeError> {
    addresses()?
        .bookshelf
        .clone()
        .send(BookshelfAdd {
            feed_id,
            source_book_id,
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
    addresses()?
        .bookshelf
        .clone()
        .send(BookshelfList)
        .await?
}

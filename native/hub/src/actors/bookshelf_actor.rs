use async_trait::async_trait;
use langhuan::cache::download_cover;
use langhuan::db::Db;
use langhuan::db::repo::{BookshelfRepo, ShelfItem};
use messages::prelude::{Actor, Context, Handler};

use crate::api::types::{
    BookshelfAddOutcome, BookshelfListItem, BookshelfRemoveOutcome, BridgeError,
};

use super::app_data_actor::InitializeAppDataDirectory;

// ---------------------------------------------------------------------------
// FRB-facing messages
// ---------------------------------------------------------------------------

/// Add a book to the shelf.
///
/// Carries a display snapshot (title/author/cover/description) taken from the
/// search result or detail page the user is looking at, so the shelf renders
/// instantly and independent of feed availability.
pub struct BookshelfAdd {
    pub feed_id: String,
    pub source_book_id: String,
    pub title: String,
    pub author: String,
    pub cover_url: Option<String>,
    pub description: Option<String>,
}

pub struct BookshelfRemove {
    pub feed_id: String,
    pub source_book_id: String,
}

pub struct BookshelfList;

/// Record the chapter count the user has just seen for a shelved book.
pub struct BookshelfMarkSeen {
    pub feed_id: String,
    pub source_book_id: String,
    pub chapter_count: i64,
}

// ---------------------------------------------------------------------------
// Actor
// ---------------------------------------------------------------------------

pub struct BookshelfActor {
    db: Option<Db>,
}

impl Actor for BookshelfActor {}

impl BookshelfActor {
    pub fn new() -> Self {
        Self { db: None }
    }

    fn db(&self) -> Result<&Db, BridgeError> {
        self.db
            .as_ref()
            .ok_or_else(|| BridgeError::from(t!("error.app_data_dir_not_set").to_string()))
    }

    async fn add(&mut self, msg: BookshelfAdd) -> Result<BookshelfAddOutcome, BridgeError> {
        tracing::debug!(feed_id = %msg.feed_id, source_book_id = %msg.source_book_id, "bookshelf add");
        let db = self.db()?.clone();
        let spawn_url = msg.cover_url.clone();
        let (feed_id, book_id) = (msg.feed_id.clone(), msg.source_book_id.clone());

        let added = db
            .write({
                let BookshelfAdd {
                    feed_id,
                    source_book_id,
                    title,
                    author,
                    cover_url,
                    description,
                } = msg;
                move |conn| {
                    conn.add_book(
                        &feed_id,
                        &source_book_id,
                        &title,
                        &author,
                        description.as_deref(),
                        cover_url.as_deref(),
                        langhuan::db::now_ms(),
                    )
                }
            })
            .await?;

        // Whether the download actually runs is decided by the claim inside
        // `download_cover` (single-flight, failure backoff, drift repair) —
        // spawning here is always safe.
        if let Some(url) = spawn_url {
            tokio::spawn(download_cover(db, feed_id, book_id, url));
        }

        Ok(if added {
            BookshelfAddOutcome::Added
        } else {
            BookshelfAddOutcome::AlreadyExists
        })
    }

    async fn remove(
        &mut self,
        msg: BookshelfRemove,
    ) -> Result<BookshelfRemoveOutcome, BridgeError> {
        tracing::debug!(feed_id = %msg.feed_id, source_book_id = %msg.source_book_id, "bookshelf remove");
        let db = self.db()?.clone();
        let removed = db
            .write({
                let feed_id = msg.feed_id;
                let book_id = msg.source_book_id;
                move |conn| conn.remove_book(&feed_id, &book_id)
            })
            .await?;

        Ok(if removed {
            BookshelfRemoveOutcome::Removed
        } else {
            BookshelfRemoveOutcome::NotFound
        })
    }

    async fn list(&mut self) -> Result<Vec<BookshelfListItem>, BridgeError> {
        tracing::debug!("bookshelf list");
        let db = self.db()?.clone();
        let items = db.call(|conn| conn.shelf_items()).await?;

        Ok(items.into_iter().map(Into::into).collect())
    }
}

/// Map a stored shelf row to its bridge representation.
impl From<ShelfItem> for BookshelfListItem {
    fn from(item: ShelfItem) -> Self {
        BookshelfListItem {
            feed_id: item.feed_id,
            source_book_id: item.book_id,
            title: item.title,
            author: item.author,
            cover_url: item.cover_url,
            description_snapshot: item.description,
            added_at_unix_ms: item.added_at_ms,
            last_seen_chapters: item.last_seen_chapters,
        }
    }
}

// ---------------------------------------------------------------------------
// Handler impls
// ---------------------------------------------------------------------------

#[async_trait]
impl Handler<InitializeAppDataDirectory> for BookshelfActor {
    type Result = Result<(), String>;

    async fn handle(
        &mut self,
        message: InitializeAppDataDirectory,
        _: &Context<Self>,
    ) -> Self::Result {
        tracing::info!("initializing bookshelf actor storage");
        self.db = Some(message.db);
        Ok(())
    }
}

#[async_trait]
impl Handler<BookshelfAdd> for BookshelfActor {
    type Result = Result<BookshelfAddOutcome, BridgeError>;

    async fn handle(&mut self, msg: BookshelfAdd, _: &Context<Self>) -> Self::Result {
        self.add(msg).await
    }
}

#[async_trait]
impl Handler<BookshelfRemove> for BookshelfActor {
    type Result = Result<BookshelfRemoveOutcome, BridgeError>;

    async fn handle(&mut self, msg: BookshelfRemove, _: &Context<Self>) -> Self::Result {
        self.remove(msg).await
    }
}

#[async_trait]
impl Handler<BookshelfList> for BookshelfActor {
    type Result = Result<Vec<BookshelfListItem>, BridgeError>;

    async fn handle(&mut self, _: BookshelfList, _: &Context<Self>) -> Self::Result {
        self.list().await
    }
}

#[async_trait]
impl Handler<BookshelfMarkSeen> for BookshelfActor {
    type Result = Result<(), BridgeError>;

    async fn handle(&mut self, msg: BookshelfMarkSeen, _: &Context<Self>) -> Self::Result {
        tracing::debug!(
            feed_id = %msg.feed_id,
            source_book_id = %msg.source_book_id,
            chapter_count = msg.chapter_count,
            "bookshelf mark seen"
        );
        let db = self.db()?.clone();
        db.write({
            let BookshelfMarkSeen {
                feed_id,
                source_book_id,
                chapter_count,
            } = msg;
            move |conn| conn.set_last_seen_chapters(&feed_id, &source_book_id, chapter_count)
        })
        .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::error::Error;

    use langhuan::db::Db;
    use langhuan::db::repo::FeedsRepo;
    use langhuan::feed::FeedMeta;
    use messages::prelude::Context;

    use super::*;

    type TestResult = Result<(), Box<dyn Error>>;

    fn meta(id: &str) -> FeedMeta {
        FeedMeta {
            id: id.to_owned(),
            name: format!("Feed {id}"),
            version: "1.0.0".to_owned(),
            author: None,
            description: None,
            base_url: "https://example.com".to_owned(),
            access_domains: Default::default(),
            schema_version: 1,
        }
    }

    #[tokio::test]
    async fn add_list_remove_roundtrip() -> TestResult {
        let db = Db::open_in_memory().await?;
        db.write(move |conn| conn.upsert_feed(&meta("f1"), None, "h", 1))
            .await?;

        let context: Context<BookshelfActor> = Context::new();
        let _addr = context.address();
        let mut actor = BookshelfActor::new();
        actor
            .handle(
                InitializeAppDataDirectory { db: db.clone() },
                &Context::new(),
            )
            .await
            .map_err(std::io::Error::other)?;

        // Add two books (second is a duplicate add).
        let added = actor
            .add(BookshelfAdd {
                feed_id: "f1".to_owned(),
                source_book_id: "b1".to_owned(),
                title: "Book One".to_owned(),
                author: "Author".to_owned(),
                cover_url: None,
                description: Some("Desc".to_owned()),
            })
            .await
            .map_err(|e| std::io::Error::other(e.message))?;
        assert!(matches!(added, BookshelfAddOutcome::Added));

        // Re-adding an existing book is a no-op for the outcome, but while
        // the row is still a placeholder the newest snapshot wins.
        let again = actor
            .add(BookshelfAdd {
                feed_id: "f1".to_owned(),
                source_book_id: "b1".to_owned(),
                title: "Book One".to_owned(),
                author: "Author".to_owned(),
                cover_url: None,
                description: Some("Newer desc".to_owned()),
            })
            .await
            .map_err(|e| std::io::Error::other(e.message))?;
        assert!(matches!(again, BookshelfAddOutcome::AlreadyExists));

        let items = actor
            .list()
            .await
            .map_err(|e| std::io::Error::other(e.message))?;
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].title, "Book One");
        assert_eq!(items[0].description_snapshot.as_deref(), Some("Newer desc"));

        let removed = actor
            .remove(BookshelfRemove {
                feed_id: "f1".to_owned(),
                source_book_id: "b1".to_owned(),
            })
            .await
            .map_err(|e| std::io::Error::other(e.message))?;
        assert!(matches!(removed, BookshelfRemoveOutcome::Removed));

        let missing = actor
            .remove(BookshelfRemove {
                feed_id: "f1".to_owned(),
                source_book_id: "b1".to_owned(),
            })
            .await
            .map_err(|e| std::io::Error::other(e.message))?;
        assert!(matches!(missing, BookshelfRemoveOutcome::NotFound));
        Ok(())
    }
}

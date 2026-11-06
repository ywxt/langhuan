use async_trait::async_trait;
use langhuan::cache::CoverDownloader;
use langhuan::db::Db;
use langhuan::db::repo::ShelfItem;
use langhuan::feed::Feed;
use messages::prelude::{Actor, Address, Context, Handler};

use crate::api::types::{
    BookshelfAddOutcome, BookshelfListItem, BookshelfRemoveOutcome, BridgeError,
};

use super::app_data_actor::InitializeAppDataDirectory;
use super::registry_actor::{GetFeed, RegistryActor};

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
    /// Supplies the feed instance a cover download runs through — the feed's
    /// own HTTP client, not a private one.
    registry_addr: Address<RegistryActor>,
}

impl Actor for BookshelfActor {}

impl BookshelfActor {
    pub fn new(registry_addr: Address<RegistryActor>) -> Self {
        Self {
            db: None,
            registry_addr,
        }
    }

    fn db(&self) -> Result<&Db, BridgeError> {
        self.db.as_ref().ok_or_else(BridgeError::not_initialized)
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

        // The cover download runs through the book's own feed client — the
        // same connection pool and `access_domains` policy as its script
        // requests. The feed is resolved *inside* the spawned task: the
        // registry's mailbox is bounded, and an add must never queue behind
        // it (nor hold this actor's mailbox while waiting). When the feed
        // cannot be resolved right now, the download is deferred, not
        // failed — the `book_info` drift repair re-spawns it on the next
        // shelved detail fetch once the feed is healthy again. Whether a
        // download actually runs is decided by the claim inside
        // `CoverDownloader::download` (single-flight, failure backoff,
        // drift repair) — spawning here is always safe.
        if let Some(url) = spawn_url {
            let mut registry_addr = self.registry_addr.clone();
            tokio::spawn(async move {
                let client = match registry_addr
                    .send(GetFeed {
                        feed_id: feed_id.clone(),
                    })
                    .await
                {
                    Ok(Ok(feed)) => feed.http_client().clone(),
                    Ok(Err(e)) => {
                        tracing::warn!(feed_id = %feed_id, error = %e, "cover download deferred: feed unavailable");
                        return;
                    }
                    Err(e) => {
                        tracing::warn!(feed_id = %feed_id, error = %e, "cover download deferred: registry unreachable");
                        return;
                    }
                };
                CoverDownloader::new(db, client)
                    .download(feed_id, book_id, url)
                    .await;
            });
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
                move |repo| repo.remove_book(&feed_id, &book_id)
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
        let items = db.call(|repo| repo.shelf_items()).await?;

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
            feed_enabled: item.feed_enabled,
            progress_current_chapter: item.progress_current_chapter,
            progress_total_chapters: item.progress_total_chapters,
            progress_chapter_title: item.progress_chapter_title,
            progress_current_paragraph: item.progress_current_paragraph,
            progress_total_paragraphs: item.progress_total_paragraphs,
        }
    }
}

// ---------------------------------------------------------------------------
// Handler impls
// ---------------------------------------------------------------------------

#[async_trait]
impl Handler<InitializeAppDataDirectory> for BookshelfActor {
    type Result = Result<(), BridgeError>;

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
            move |repo| repo.set_last_seen_chapters(&feed_id, &source_book_id, chapter_count)
        })
        .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::error::Error;

    use langhuan::db::Db;
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
        db.write(move |repo| repo.upsert_feed(&meta("f1"), None, "h", 1))
            .await?;

        let context: Context<BookshelfActor> = Context::new();
        let _addr = context.address();
        // A registry context nobody runs: its mailbox accepts messages but
        // nothing ever replies, so an add that waited on the registry inline
        // would hang forever — exactly what the cover test below guards
        // against. Keeping the context alive (instead of a dropped one)
        // makes the send block rather than error out.
        let registry_context: Context<RegistryActor> = Context::new();
        let mut actor = BookshelfActor::new(registry_context.address());
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

        // A cover URL must not tie the add to the registry: the feed is
        // resolved inside the spawned download task, and this add (against
        // a registry that will never reply) must return promptly — under
        // the inline-round-trip version it hangs.
        let with_cover = tokio::time::timeout(
            std::time::Duration::from_secs(1),
            actor.add(BookshelfAdd {
                feed_id: "f1".to_owned(),
                source_book_id: "b2".to_owned(),
                title: "Book Two".to_owned(),
                author: "Author".to_owned(),
                cover_url: Some("https://example.com/cover".to_owned()),
                description: None,
            }),
        )
        .await
        .expect("add must not wait on the registry")
        .map_err(|e| std::io::Error::other(e.message))?;
        assert!(matches!(with_cover, BookshelfAddOutcome::Added));

        let items = actor
            .list()
            .await
            .map_err(|e| std::io::Error::other(e.message))?;
        assert_eq!(items.len(), 2);
        // The shelf sorts newest-first; find by id so the assertion does not
        // depend on the same-millisecond ordering tiebreak.
        let b1 = items
            .iter()
            .find(|i| i.source_book_id == "b1")
            .expect("b1 shelved");
        assert_eq!(b1.title, "Book One");
        assert_eq!(b1.description_snapshot.as_deref(), Some("Newer desc"));
        let b2 = items
            .iter()
            .find(|i| i.source_book_id == "b2")
            .expect("b2 shelved");
        assert_eq!(b2.title, "Book Two");
        assert_eq!(b2.cover_url.as_deref(), Some("https://example.com/cover"));

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

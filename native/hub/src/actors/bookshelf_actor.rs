use async_trait::async_trait;
use langhuan::bookshelf::{
    BookIdentity, BookshelfEntry, LocalBookshelf, LocalBookshelfAddOutcome,
    LocalBookshelfRemoveOutcome,
};
use langhuan::feed::Feed;
use messages::prelude::{Actor, Address, Context, Handler};

use crate::api::types::{
    BookshelfAddOutcome, BookshelfListItem, BookshelfRemoveOutcome, BridgeError,
};

use super::app_data_actor::InitializeAppDataDirectory;
use super::registry_actor::GetFeed;
use super::registry_actor::RegistryActor;

// ---------------------------------------------------------------------------
// FRB-facing messages
// ---------------------------------------------------------------------------

pub struct BookshelfAdd {
    pub feed_id: String,
    pub source_book_id: String,
}

pub struct BookshelfRemove {
    pub feed_id: String,
    pub source_book_id: String,
}

pub struct BookshelfList;

// ---------------------------------------------------------------------------
// Actor
// ---------------------------------------------------------------------------

pub struct BookshelfActor {
    registry_addr: Address<RegistryActor>,
    shelf: Option<LocalBookshelf>,
}

impl Actor for BookshelfActor {}

impl BookshelfActor {
    pub fn new(registry_addr: Address<RegistryActor>) -> Self {
        Self {
            registry_addr,
            shelf: None,
        }
    }

    async fn set_data_directory(&mut self, path: &std::path::Path) -> Result<(), String> {
        let path = bookshelf_file(path);
        tracing::info!(path = %path.display(), "initializing bookshelf actor storage");
        if let Some(parent) = path.parent()
            && let Err(e) = tokio::fs::create_dir_all(parent).await
        {
            let message = e.to_string();
            tracing::error!(error = %message, "failed to create bookshelf directory");
            self.shelf = None;
            return Err(message);
        }
        match LocalBookshelf::open(path).await {
            Ok(shelf) => {
                self.shelf = Some(shelf);
                tracing::info!("bookshelf actor storage initialized");
                Ok(())
            }
            Err(e) => {
                let message = e.to_string();
                tracing::error!(error = %message, "failed to initialize local bookshelf");
                self.shelf = None;
                Err(message)
            }
        }
    }

    fn unavailable_message(&self) -> String {
        t!("error.bookshelf_unavailable").to_string()
    }

    async fn add(&mut self, feed_id: String, source_book_id: String) -> Result<BookshelfAddOutcome, BridgeError> {
        tracing::debug!(feed_id = %feed_id, source_book_id = %source_book_id, "bookshelf add");
        let identity = BookIdentity {
            feed_id,
            source_book_id,
        };
        let entry = BookshelfEntry {
            identity,
            added_at_unix_ms: now_unix_ms(),
        };

        match self.shelf.as_mut() {
            Some(shelf) => match shelf.add(entry).await {
                Ok(LocalBookshelfAddOutcome::Added) => Ok(BookshelfAddOutcome::Added),
                Ok(LocalBookshelfAddOutcome::AlreadyExists) => Ok(BookshelfAddOutcome::AlreadyExists),
                Err(e) => Err(BridgeError::from(e.to_string())),
            },
            None => Err(BridgeError::from(self.unavailable_message())),
        }
    }

    async fn remove(&mut self, feed_id: String, source_book_id: String) -> Result<BookshelfRemoveOutcome, BridgeError> {
        tracing::debug!(feed_id = %feed_id, source_book_id = %source_book_id, "bookshelf remove");
        let identity = BookIdentity {
            feed_id,
            source_book_id,
        };

        match self.shelf.as_mut() {
            Some(shelf) => match shelf.remove(&identity).await {
                Ok(LocalBookshelfRemoveOutcome::Removed) => Ok(BookshelfRemoveOutcome::Removed),
                Ok(LocalBookshelfRemoveOutcome::NotFound) => Ok(BookshelfRemoveOutcome::NotFound),
                Err(e) => Err(BridgeError::from(e.to_string())),
            },
            None => Err(BridgeError::from(self.unavailable_message())),
        }
    }

    async fn list(&mut self) -> Result<Vec<BookshelfListItem>, BridgeError> {
        tracing::debug!("bookshelf list");
        let shelf = self
            .shelf
            .as_ref()
            .ok_or_else(|| BridgeError::from(self.unavailable_message()))?;

        let entries = shelf.entries().to_vec();
        let mut items = Vec::with_capacity(entries.len());

        for entry in entries {
            let identity = entry.identity;
            let (title, author, cover_url, description_snapshot) = match self
                .registry_addr
                .send(GetFeed {
                    feed_id: identity.feed_id.clone(),
                })
                .await
            {
                Ok(Ok(feed)) => match feed.book_info(&identity.source_book_id).await {
                    Ok(book) => (book.title, book.author, book.cover_url, book.description),
                    Err(e) => {
                        tracing::warn!(
                            feed_id = %identity.feed_id,
                            source_book_id = %identity.source_book_id,
                            error = %e,
                            "failed to resolve book_info while listing bookshelf"
                        );
                        (identity.source_book_id.clone(), String::new(), None, None)
                    }
                },
                Ok(Err(e)) => {
                    tracing::warn!(
                        feed_id = %identity.feed_id,
                        source_book_id = %identity.source_book_id,
                        error = %e,
                        "failed to resolve feed while listing bookshelf"
                    );
                    (identity.source_book_id.clone(), String::new(), None, None)
                }
                Err(e) => {
                    tracing::warn!(
                        feed_id = %identity.feed_id,
                        source_book_id = %identity.source_book_id,
                        error = %e,
                        "failed to request feed actor while listing bookshelf"
                    );
                    (identity.source_book_id.clone(), String::new(), None, None)
                }
            };

            items.push(BookshelfListItem {
                feed_id: identity.feed_id,
                source_book_id: identity.source_book_id,
                title,
                author,
                cover_url,
                description_snapshot,
                added_at_unix_ms: entry.added_at_unix_ms,
            });
        }

        Ok(items)
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
        self.set_data_directory(std::path::Path::new(&message.path))
            .await
    }
}

#[async_trait]
impl Handler<BookshelfAdd> for BookshelfActor {
    type Result = Result<BookshelfAddOutcome, BridgeError>;

    async fn handle(&mut self, msg: BookshelfAdd, _: &Context<Self>) -> Self::Result {
        self.add(msg.feed_id, msg.source_book_id).await
    }
}

#[async_trait]
impl Handler<BookshelfRemove> for BookshelfActor {
    type Result = Result<BookshelfRemoveOutcome, BridgeError>;

    async fn handle(&mut self, msg: BookshelfRemove, _: &Context<Self>) -> Self::Result {
        self.remove(msg.feed_id, msg.source_book_id).await
    }
}

#[async_trait]
impl Handler<BookshelfList> for BookshelfActor {
    type Result = Result<Vec<BookshelfListItem>, BridgeError>;

    async fn handle(&mut self, _: BookshelfList, _: &Context<Self>) -> Self::Result {
        self.list().await
    }
}

fn now_unix_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};

    match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(duration) => duration.as_millis() as i64,
        Err(_) => 0,
    }
}

fn bookshelf_file(base_dir: &std::path::Path) -> std::path::PathBuf {
    base_dir.join("bookshelf").join("bookshelf.json")
}

#[cfg(test)]
mod tests {
    use std::error::Error;

    use messages::prelude::Context;

    use super::*;

    type TestResult = Result<(), Box<dyn Error>>;

    #[tokio::test]
    async fn set_app_data_directory_writes_bookshelf_under_bookshelf_subdir() -> TestResult {
        let dir = tempfile::tempdir()?;

        let registry_context = Context::new();
        let registry_address = registry_context.address();

        let bookshelf_context: Context<BookshelfActor> = Context::new();
        let _bookshelf_address = bookshelf_context.address();
        let mut actor = BookshelfActor::new(registry_address);

        actor
            .set_data_directory(dir.path())
            .await
            .map_err(std::io::Error::other)?;

        assert!(dir.path().join("bookshelf").is_dir());
        Ok(())
    }
}

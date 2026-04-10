use async_trait::async_trait;
use langhuan::bookshelf::{
    BookIdentity, BookshelfEntry, LocalBookshelf, LocalBookshelfAddOutcome,
    LocalBookshelfRemoveOutcome,
};
use langhuan::feed::Feed;
use messages::prelude::{Actor, Address, Context, Handler, Notifiable};
use rinf::{DartSignal, RustSignal};
use tokio::task::JoinSet;

use crate::signals::{
    BookshelfAddRequest, BookshelfAddResult, BookshelfListEnd, BookshelfListItem,
    BookshelfListOutcome, BookshelfListRequest, BookshelfRemoveRequest, BookshelfRemoveResult,
};

use super::app_data_actor::InitializeAppDataDirectory;
use super::registry_actor::GetFeed;
use super::registry_actor::RegistryActor;

pub struct BookshelfActor {
    registry_addr: Address<RegistryActor>,
    shelf: Option<LocalBookshelf>,
    _owned_tasks: JoinSet<()>,
}

impl Actor for BookshelfActor {}

impl BookshelfActor {
    pub fn new(self_addr: Address<Self>, registry_addr: Address<RegistryActor>) -> Self {
        let mut _owned_tasks = JoinSet::new();
        _owned_tasks.spawn(Self::listen_to_add(self_addr.clone()));
        _owned_tasks.spawn(Self::listen_to_remove(self_addr.clone()));
        _owned_tasks.spawn(Self::listen_to_list(self_addr));

        Self {
            registry_addr,
            shelf: None,
            _owned_tasks,
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

    async fn add(&mut self, req: BookshelfAddRequest) -> BookshelfAddResult {
        tracing::debug!(
            request_id = %req.request_id,
            feed_id = %req.feed_id,
            source_book_id = %req.source_book_id,
            "received bookshelf add request"
        );
        let request_id = req.request_id;
        let identity = BookIdentity {
            feed_id: req.feed_id,
            source_book_id: req.source_book_id,
        };

        let entry = BookshelfEntry {
            identity,
            added_at_unix_ms: now_unix_ms(),
        };

        match self.shelf.as_mut() {
            Some(shelf) => match shelf.add(entry).await {
                Ok(LocalBookshelfAddOutcome::Added) => BookshelfAddResult::success(request_id),
                Ok(LocalBookshelfAddOutcome::AlreadyExists) => {
                    BookshelfAddResult::already_exists(request_id)
                }
                Err(e) => BookshelfAddResult::error(request_id, e.to_string()),
            },
            None => BookshelfAddResult::error(request_id, self.unavailable_message()),
        }
    }

    async fn remove(&mut self, req: BookshelfRemoveRequest) -> BookshelfRemoveResult {
        tracing::debug!(
            request_id = %req.request_id,
            feed_id = %req.feed_id,
            source_book_id = %req.source_book_id,
            "received bookshelf remove request"
        );
        let request_id = req.request_id;
        let identity = BookIdentity {
            feed_id: req.feed_id,
            source_book_id: req.source_book_id,
        };

        match self.shelf.as_mut() {
            Some(shelf) => match shelf.remove(&identity).await {
                Ok(LocalBookshelfRemoveOutcome::Removed) => {
                    BookshelfRemoveResult::success(request_id)
                }
                Ok(LocalBookshelfRemoveOutcome::NotFound) => {
                    BookshelfRemoveResult::not_found(request_id)
                }
                Err(e) => BookshelfRemoveResult::error(request_id, e.to_string()),
            },
            None => BookshelfRemoveResult::error(request_id, self.unavailable_message()),
        }
    }

    async fn list(&mut self, req: BookshelfListRequest) {
        tracing::debug!(request_id = %req.request_id, "received bookshelf list request");
        if let Some(shelf) = &self.shelf {
            let entries = shelf.entries().to_vec();
            tracing::debug!(request_id = %req.request_id, entries = entries.len(), "emitting bookshelf list items");
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
                                request_id = %req.request_id,
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
                            request_id = %req.request_id,
                            feed_id = %identity.feed_id,
                            source_book_id = %identity.source_book_id,
                            error = %e,
                            "failed to resolve feed while listing bookshelf"
                        );
                        (identity.source_book_id.clone(), String::new(), None, None)
                    }
                    Err(e) => {
                        tracing::warn!(
                            request_id = %req.request_id,
                            feed_id = %identity.feed_id,
                            source_book_id = %identity.source_book_id,
                            error = %e,
                            "failed to request feed actor while listing bookshelf"
                        );
                        (identity.source_book_id.clone(), String::new(), None, None)
                    }
                };

                BookshelfListItem {
                    request_id: req.request_id.clone(),
                    feed_id: identity.feed_id,
                    source_book_id: identity.source_book_id,
                    title,
                    author,
                    cover_url,
                    description_snapshot,
                    added_at_unix_ms: entry.added_at_unix_ms,
                }
                .send_signal_to_dart();
            }
            BookshelfListEnd {
                request_id: req.request_id,
                outcome: BookshelfListOutcome::Completed,
            }
            .send_signal_to_dart();
            return;
        }

        BookshelfListEnd {
            request_id: req.request_id,
            outcome: BookshelfListOutcome::Failed {
                message: self.unavailable_message(),
            },
        }
        .send_signal_to_dart();
    }

    async fn listen_to_add(mut self_addr: Address<Self>) {
        let receiver = BookshelfAddRequest::get_dart_signal_receiver();
        while let Some(signal_pack) = receiver.recv().await {
            let _ = self_addr.notify(signal_pack.message).await;
        }
    }

    async fn listen_to_remove(mut self_addr: Address<Self>) {
        let receiver = BookshelfRemoveRequest::get_dart_signal_receiver();
        while let Some(signal_pack) = receiver.recv().await {
            let _ = self_addr.notify(signal_pack.message).await;
        }
    }

    async fn listen_to_list(mut self_addr: Address<Self>) {
        let receiver = BookshelfListRequest::get_dart_signal_receiver();
        while let Some(signal_pack) = receiver.recv().await {
            let _ = self_addr.notify(signal_pack.message).await;
        }
    }
}

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
impl Notifiable<BookshelfAddRequest> for BookshelfActor {
    async fn notify(&mut self, message: BookshelfAddRequest, _: &Context<Self>) {
        self.add(message).await.send_signal_to_dart();
    }
}

#[async_trait]
impl Notifiable<BookshelfRemoveRequest> for BookshelfActor {
    async fn notify(&mut self, message: BookshelfRemoveRequest, _: &Context<Self>) {
        self.remove(message).await.send_signal_to_dart();
    }
}

#[async_trait]
impl Notifiable<BookshelfListRequest> for BookshelfActor {
    async fn notify(&mut self, message: BookshelfListRequest, _: &Context<Self>) {
        self.list(message).await;
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
    use std::io;

    use crate::signals::BookshelfOperationOutcome;
    use messages::prelude::Context;

    use super::*;

    type TestResult = Result<(), Box<dyn Error>>;

    #[tokio::test]
    async fn set_app_data_directory_writes_bookshelf_under_bookshelf_subdir() -> TestResult {
        let dir = tempfile::tempdir()?;

        let registry_context = Context::new();
        let registry_address = registry_context.address();

        let bookshelf_context = Context::new();
        let bookshelf_address = bookshelf_context.address();
        let mut actor = BookshelfActor::new(bookshelf_address, registry_address);

        actor
            .set_data_directory(dir.path())
            .await
            .map_err(io::Error::other)?;

        let result = actor
            .add(BookshelfAddRequest {
                request_id: "req-1".to_owned(),
                feed_id: "feed-a".to_owned(),
                source_book_id: "book-1".to_owned(),
            })
            .await;

        assert!(matches!(result.outcome, BookshelfOperationOutcome::Success));
        assert!(dir.path().join("bookshelf").is_dir());
        assert!(dir.path().join("bookshelf/bookshelf.json").is_file());
        assert!(!dir.path().join("bookshelf.json").exists());
        Ok(())
    }

    #[tokio::test]
    async fn set_app_data_directory_keeps_followup_requests_generic_when_unavailable() -> TestResult
    {
        let dir = tempfile::tempdir()?;
        let blocked_path = dir.path().join("blocked");
        std::fs::write(&blocked_path, "file")?;

        let registry_context = Context::new();
        let registry_address = registry_context.address();

        let bookshelf_context = Context::new();
        let bookshelf_address = bookshelf_context.address();
        let mut actor = BookshelfActor::new(bookshelf_address, registry_address);

        if actor.set_data_directory(&blocked_path).await.is_ok() {
            return Err(io::Error::other("set data directory should fail").into());
        }

        let result = actor
            .add(BookshelfAddRequest {
                request_id: "req-2".to_owned(),
                feed_id: "feed-a".to_owned(),
                source_book_id: "book-2".to_owned(),
            })
            .await;

        match result.outcome {
            BookshelfOperationOutcome::Error { message } => {
                assert_eq!(message, t!("error.bookshelf_unavailable").to_string());
                Ok(())
            }
            _ => Err(io::Error::other("expected error outcome").into()),
        }
    }
}

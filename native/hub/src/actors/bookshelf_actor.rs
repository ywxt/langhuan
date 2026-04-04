use async_trait::async_trait;
use langhuan::bookshelf::{
    BookIdentity, BookshelfEntry, LocalBookshelf, LocalBookshelfAddOutcome,
    LocalBookshelfRemoveOutcome,
};
use langhuan::feed::FeedBookshelfSupport;
use messages::prelude::{Actor, Address, Context, Handler, Notifiable};
use rinf::{DartSignal, RustSignal};
use tokio::task::JoinSet;

use crate::signals::{
    BookshelfAddRequest, BookshelfAddResult, BookshelfCapabilitiesRequest,
    BookshelfCapabilitiesResult, BookshelfListEnd, BookshelfListItem, BookshelfListOutcome,
    BookshelfListRequest, BookshelfOperationOutcome, BookshelfRemoveRequest, BookshelfRemoveResult,
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
        _owned_tasks.spawn(Self::listen_to_list(self_addr.clone()));
        _owned_tasks.spawn(Self::listen_to_capabilities(self_addr));

        Self {
            registry_addr,
            shelf: None,
            _owned_tasks,
        }
    }

    async fn set_data_directory(&mut self, path: &std::path::Path) -> Result<(), String> {
        let path = bookshelf_file(path);
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
        let identity = BookIdentity {
            feed_id: req.feed_id,
            source_book_id: req.source_book_id,
        };

        let entry = BookshelfEntry {
            identity,
            title: req.title,
            author: req.author,
            cover_url: req.cover_url,
            description_snapshot: req.description_snapshot,
            source_name_snapshot: None,
            added_at_unix_ms: now_unix_ms(),
        };

        let outcome = match self.shelf.as_mut() {
            Some(shelf) => match shelf.add(entry).await {
                Ok(LocalBookshelfAddOutcome::Added) => BookshelfOperationOutcome::Success,
                Ok(LocalBookshelfAddOutcome::AlreadyExists) => {
                    BookshelfOperationOutcome::AlreadyExists
                }
                Err(e) => BookshelfOperationOutcome::Error {
                    message: e.to_string(),
                },
            },
            None => BookshelfOperationOutcome::Error {
                message: self.unavailable_message(),
            },
        };

        BookshelfAddResult {
            request_id: req.request_id,
            outcome,
        }
    }

    async fn remove(&mut self, req: BookshelfRemoveRequest) -> BookshelfRemoveResult {
        let identity = BookIdentity {
            feed_id: req.feed_id,
            source_book_id: req.source_book_id,
        };

        let outcome = match self.shelf.as_mut() {
            Some(shelf) => match shelf.remove(&identity).await {
                Ok(LocalBookshelfRemoveOutcome::Removed) => BookshelfOperationOutcome::Success,
                Ok(LocalBookshelfRemoveOutcome::NotFound) => BookshelfOperationOutcome::NotFound,
                Err(e) => BookshelfOperationOutcome::Error {
                    message: e.to_string(),
                },
            },
            None => BookshelfOperationOutcome::Error {
                message: self.unavailable_message(),
            },
        };

        BookshelfRemoveResult {
            request_id: req.request_id,
            outcome,
        }
    }

    fn list(&self, req: BookshelfListRequest) {
        if let Some(shelf) = &self.shelf {
            for entry in shelf.entries() {
                BookshelfListItem {
                    request_id: req.request_id.clone(),
                    feed_id: entry.identity.feed_id.clone(),
                    source_book_id: entry.identity.source_book_id.clone(),
                    title: entry.title.clone(),
                    author: entry.author.clone(),
                    cover_url: entry.cover_url.clone(),
                    description_snapshot: entry.description_snapshot.clone(),
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

    async fn capabilities(
        &mut self,
        req: BookshelfCapabilitiesRequest,
    ) -> BookshelfCapabilitiesResult {
        let supports_bookshelf = match self
            .registry_addr
            .send(GetFeed {
                feed_id: req.feed_id.clone(),
            })
            .await
        {
            Ok(Ok(feed)) => feed.bookshelf_capabilities().supports_bookshelf,
            _ => false,
        };

        BookshelfCapabilitiesResult {
            request_id: req.request_id,
            feed_id: req.feed_id,
            supports_bookshelf,
        }
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

    async fn listen_to_capabilities(mut self_addr: Address<Self>) {
        let receiver = BookshelfCapabilitiesRequest::get_dart_signal_receiver();
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
        self.list(message);
    }
}

#[async_trait]
impl Notifiable<BookshelfCapabilitiesRequest> for BookshelfActor {
    async fn notify(&mut self, message: BookshelfCapabilitiesRequest, _: &Context<Self>) {
        self.capabilities(message).await.send_signal_to_dart();
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
    base_dir.join("bookshelf").join("bookshelf.toml")
}

#[cfg(test)]
mod tests {
    use std::error::Error;
    use std::io;

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
                title: "Book One".to_owned(),
                author: "Author".to_owned(),
                cover_url: None,
                description_snapshot: None,
            })
            .await;

        assert!(matches!(result.outcome, BookshelfOperationOutcome::Success));
        assert!(dir.path().join("bookshelf").is_dir());
        assert!(dir.path().join("bookshelf/bookshelf.toml").is_file());
        assert!(!dir.path().join("bookshelf.toml").exists());
        Ok(())
    }

    #[tokio::test]
    async fn set_app_data_directory_keeps_followup_requests_generic_when_unavailable() -> TestResult {
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
                title: "Book Two".to_owned(),
                author: "Author".to_owned(),
                cover_url: None,
                description_snapshot: None,
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

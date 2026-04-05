use std::path::Path;
use std::sync::Arc;

use async_trait::async_trait;
use langhuan::progress::{ReadingProgress, ReadingProgressStore};
use messages::prelude::{Actor, Address, Context, Handler, Notifiable};
use rinf::{DartSignal, RustSignal};
use tokio::task::JoinSet;

use crate::localize_error;
use crate::signals::{
    ReadingProgressGetOutcome, ReadingProgressGetRequest, ReadingProgressGetResult,
    ReadingProgressItem, ReadingProgressSetOutcome, ReadingProgressSetRequest,
    ReadingProgressSetResult,
};

use super::app_data_actor::InitializeAppDataDirectory;

pub struct ReadingProgressActor {
    store: Option<Arc<ReadingProgressStore>>,
    _owned_tasks: JoinSet<()>,
}

impl Actor for ReadingProgressActor {}

impl ReadingProgressActor {
    pub fn new(self_addr: Address<Self>) -> Self {
        let mut _owned_tasks = JoinSet::new();
        _owned_tasks.spawn(Self::listen_to_reading_progress_get(self_addr.clone()));
        _owned_tasks.spawn(Self::listen_to_reading_progress_set(self_addr));

        Self {
            store: None,
            _owned_tasks,
        }
    }

    async fn initialize_app_data_directory(&mut self, path: &str) -> Result<(), String> {
        let base_dir = Path::new(path);
        let progress_dir = progress_dir(base_dir);

        if let Err(e) = tokio::fs::create_dir_all(&progress_dir).await {
            return Err(e.to_string());
        }

        self.store = Some(Arc::new(ReadingProgressStore::new(progress_dir)));
        Ok(())
    }

    async fn do_reading_progress_get(
        &self,
        req: ReadingProgressGetRequest,
    ) -> ReadingProgressGetResult {
        let Some(store) = self.store.as_ref() else {
            return ReadingProgressGetResult {
                request_id: req.request_id,
                outcome: ReadingProgressGetOutcome::Error {
                    message: t!("error.app_data_dir_not_set").to_string(),
                },
            };
        };

        let outcome = match store.get_reading_progress(&req.feed_id, &req.book_id).await {
            Ok(progress) => ReadingProgressGetOutcome::Success {
                progress: progress.map(|item| ReadingProgressItem {
                    feed_id: item.feed_id,
                    book_id: item.book_id,
                    chapter_id: item.chapter_id,
                    paragraph_index: item.paragraph_index as u32,
                    updated_at_ms: item.updated_at_ms,
                }),
            },
            Err(e) => ReadingProgressGetOutcome::Error {
                message: localize_error(&e),
            },
        };

        ReadingProgressGetResult {
            request_id: req.request_id,
            outcome,
        }
    }

    async fn do_reading_progress_set(
        &self,
        req: ReadingProgressSetRequest,
    ) -> ReadingProgressSetResult {
        let Some(store) = self.store.as_ref() else {
            return ReadingProgressSetResult {
                request_id: req.request_id,
                outcome: ReadingProgressSetOutcome::Error {
                    message: t!("error.app_data_dir_not_set").to_string(),
                },
            };
        };

        let progress = ReadingProgress {
            feed_id: req.feed_id,
            book_id: req.book_id,
            chapter_id: req.chapter_id,
            paragraph_index: req.paragraph_index as usize,
            updated_at_ms: req.updated_at_ms,
        };

        let outcome = match store.set_reading_progress(progress).await {
            Ok(()) => ReadingProgressSetOutcome::Success,
            Err(e) => ReadingProgressSetOutcome::Error {
                message: localize_error(&e),
            },
        };

        ReadingProgressSetResult {
            request_id: req.request_id,
            outcome,
        }
    }

    async fn listen_to_reading_progress_get(mut self_addr: Address<Self>) {
        let receiver = ReadingProgressGetRequest::get_dart_signal_receiver();
        while let Some(signal_pack) = receiver.recv().await {
            let _ = self_addr.notify(signal_pack.message).await;
        }
    }

    async fn listen_to_reading_progress_set(mut self_addr: Address<Self>) {
        let receiver = ReadingProgressSetRequest::get_dart_signal_receiver();
        while let Some(signal_pack) = receiver.recv().await {
            let _ = self_addr.notify(signal_pack.message).await;
        }
    }
}

fn progress_dir(base_dir: &Path) -> std::path::PathBuf {
    base_dir.join("progress")
}

#[async_trait]
impl Handler<InitializeAppDataDirectory> for ReadingProgressActor {
    type Result = Result<(), String>;

    async fn handle(&mut self, msg: InitializeAppDataDirectory, _: &Context<Self>) -> Self::Result {
        self.initialize_app_data_directory(&msg.path).await
    }
}

#[async_trait]
impl Notifiable<ReadingProgressGetRequest> for ReadingProgressActor {
    async fn notify(&mut self, msg: ReadingProgressGetRequest, _: &Context<Self>) {
        self.do_reading_progress_get(msg).await.send_signal_to_dart();
    }
}

#[async_trait]
impl Notifiable<ReadingProgressSetRequest> for ReadingProgressActor {
    async fn notify(&mut self, msg: ReadingProgressSetRequest, _: &Context<Self>) {
        self.do_reading_progress_set(msg).await.send_signal_to_dart();
    }
}

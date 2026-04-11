use std::path::Path;

use async_trait::async_trait;
use langhuan::progress::{ReadingProgress, ReadingProgressStore};
use messages::prelude::{Actor, Context, Handler};

use crate::api::types::{BridgeError, ReadingProgressItem};
use crate::localize_error;

use super::app_data_actor::InitializeAppDataDirectory;

/// Message: get reading progress for a book.
pub struct GetReadingProgress {
    pub feed_id: String,
    pub book_id: String,
}

/// Message: set reading progress for a book.
pub struct SetReadingProgress {
    pub feed_id: String,
    pub book_id: String,
    pub chapter_id: String,
    pub paragraph_index: u32,
    pub updated_at_ms: i64,
}

pub struct ReadingProgressActor {
    store: Option<ReadingProgressStore>,
}

impl Actor for ReadingProgressActor {}

impl ReadingProgressActor {
    pub fn new() -> Self {
        Self { store: None }
    }

    async fn initialize_app_data_directory(&mut self, path: &str) -> Result<(), String> {
        let base_dir = Path::new(path);
        let progress_dir = progress_dir(base_dir);
        tracing::info!(path = %progress_dir.display(), "initializing reading progress storage");

        if let Err(e) = tokio::fs::create_dir_all(&progress_dir).await {
            return Err(e.to_string());
        }

        self.store = Some(
            ReadingProgressStore::open(progress_dir)
                .await
                .map_err(|e| localize_error(&e))?,
        );
        tracing::info!("reading progress storage initialized");
        Ok(())
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
impl Handler<GetReadingProgress> for ReadingProgressActor {
    type Result = Result<Option<ReadingProgressItem>, BridgeError>;

    async fn handle(&mut self, msg: GetReadingProgress, _: &Context<Self>) -> Self::Result {
        let store = self
            .store
            .as_ref()
            .ok_or_else(|| BridgeError::from(t!("error.app_data_dir_not_set").to_string()))?;

        match store.get_reading_progress(&msg.feed_id, &msg.book_id).await {
            Ok(progress) => Ok(progress.map(|item| ReadingProgressItem {
                feed_id: item.feed_id,
                book_id: item.book_id,
                chapter_id: item.chapter_id,
                paragraph_index: item.paragraph_index as u32,
                updated_at_ms: item.updated_at_ms,
            })),
            Err(e) => Err(BridgeError::from(e)),
        }
    }
}

#[async_trait]
impl Handler<SetReadingProgress> for ReadingProgressActor {
    type Result = Result<(), BridgeError>;

    async fn handle(&mut self, msg: SetReadingProgress, _: &Context<Self>) -> Self::Result {
        let store = self
            .store
            .as_mut()
            .ok_or_else(|| BridgeError::from(t!("error.app_data_dir_not_set").to_string()))?;

        let progress = ReadingProgress {
            feed_id: msg.feed_id,
            book_id: msg.book_id,
            chapter_id: msg.chapter_id,
            paragraph_index: msg.paragraph_index as usize,
            updated_at_ms: msg.updated_at_ms,
        };

        store
            .set_reading_progress(progress)
            .await
            .map_err(|e| BridgeError::from(e))
    }
}

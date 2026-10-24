use async_trait::async_trait;
use langhuan::db::repo;
use langhuan::db::Db;
use messages::prelude::{Actor, Context, Handler};

use crate::api::types::{BridgeError, ParagraphId, ReadingProgressItem};

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
    pub paragraph_id: String,
    pub updated_at_ms: i64,
}

pub struct ReadingProgressActor {
    db: Option<Db>,
}

impl Actor for ReadingProgressActor {}

impl ReadingProgressActor {
    pub fn new() -> Self {
        Self { db: None }
    }

    fn db(&self) -> Result<&Db, BridgeError> {
        self.db
            .as_ref()
            .ok_or_else(|| BridgeError::from(t!("error.app_data_dir_not_set").to_string()))
    }
}

#[async_trait]
impl Handler<InitializeAppDataDirectory> for ReadingProgressActor {
    type Result = Result<(), String>;

    async fn handle(&mut self, msg: InitializeAppDataDirectory, _: &Context<Self>) -> Self::Result {
        tracing::info!("initializing reading progress storage");
        self.db = Some(msg.db);
        Ok(())
    }
}

#[async_trait]
impl Handler<GetReadingProgress> for ReadingProgressActor {
    type Result = Result<Option<ReadingProgressItem>, BridgeError>;

    async fn handle(&mut self, msg: GetReadingProgress, _: &Context<Self>) -> Self::Result {
        let db = self.db()?.clone();
        let (feed_id, book_id) = (msg.feed_id, msg.book_id);
        let progress = db
            .call(move |conn| repo::progress::get(conn, &feed_id, &book_id))
            .await?;

        Ok(progress.map(|item| ReadingProgressItem {
            feed_id: item.feed_id,
            book_id: item.book_id,
            chapter_id: item.chapter_id,
            paragraph_id: ParagraphId::from_stored(item.paragraph_id),
            updated_at_ms: item.updated_at_ms,
        }))
    }
}

#[async_trait]
impl Handler<SetReadingProgress> for ReadingProgressActor {
    type Result = Result<(), BridgeError>;

    async fn handle(&mut self, msg: SetReadingProgress, _: &Context<Self>) -> Self::Result {
        let db = self.db()?.clone();
        let updated_at_ms = msg.updated_at_ms;
        db.write(move |conn| {
            repo::progress::set(
                conn,
                &msg.feed_id,
                &msg.book_id,
                &msg.chapter_id,
                &msg.paragraph_id,
                updated_at_ms,
            )
        })
        .await
        .map_err(BridgeError::from)
    }
}

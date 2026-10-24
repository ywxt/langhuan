use async_trait::async_trait;
use langhuan::db::repo::{BookmarkRow, BookmarksRepo};
use langhuan::db::Db;
use messages::prelude::{Actor, Context, Handler};

use crate::api::types::{BookmarkItem, BridgeError, ParagraphId};

use super::app_data_actor::InitializeAppDataDirectory;

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

pub struct AddBookmark {
    pub feed_id: String,
    pub book_id: String,
    pub chapter_id: String,
    pub paragraph_id: String,
    pub paragraph_name: String,
    pub paragraph_preview: String,
    pub label: String,
}

pub struct RemoveBookmark {
    pub id: String,
}

pub struct ListBookmarks {
    pub feed_id: String,
    pub book_id: String,
}

// ---------------------------------------------------------------------------
// Actor
// ---------------------------------------------------------------------------

pub struct BookmarkActor {
    db: Option<Db>,
}

impl Actor for BookmarkActor {}

impl BookmarkActor {
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
impl Handler<InitializeAppDataDirectory> for BookmarkActor {
    type Result = Result<(), String>;

    async fn handle(&mut self, msg: InitializeAppDataDirectory, _: &Context<Self>) -> Self::Result {
        tracing::info!("initializing bookmark storage");
        self.db = Some(msg.db);
        Ok(())
    }
}

#[async_trait]
impl Handler<AddBookmark> for BookmarkActor {
    type Result = Result<BookmarkItem, BridgeError>;

    async fn handle(&mut self, msg: AddBookmark, _: &Context<Self>) -> Self::Result {
        let db = self.db()?.clone();
        let row = BookmarkRow {
            id: uuid(),
            feed_id: msg.feed_id,
            book_id: msg.book_id,
            chapter_id: msg.chapter_id,
            paragraph_id: msg.paragraph_id,
            paragraph_name: msg.paragraph_name,
            paragraph_preview: msg.paragraph_preview,
            label: msg.label,
            created_at_ms: langhuan::db::now_ms(),
        };

        db.write({
            let row = row.clone();
            move |conn| conn.add_bookmark(&row)
        })
        .await?;

        Ok(row.into())
    }
}

#[async_trait]
impl Handler<RemoveBookmark> for BookmarkActor {
    type Result = Result<bool, BridgeError>;

    async fn handle(&mut self, msg: RemoveBookmark, _: &Context<Self>) -> Self::Result {
        let db = self.db()?.clone();
        let id = msg.id;
        db.write(move |conn| conn.remove_bookmark(&id))
            .await
            .map_err(BridgeError::from)
    }
}

#[async_trait]
impl Handler<ListBookmarks> for BookmarkActor {
    type Result = Result<Vec<BookmarkItem>, BridgeError>;

    async fn handle(&mut self, msg: ListBookmarks, _: &Context<Self>) -> Self::Result {
        let db = self.db()?.clone();
        let (feed_id, book_id) = (msg.feed_id, msg.book_id);
        let items = db
            .call(move |conn| conn.list_bookmarks(&feed_id, &book_id))
            .await?;

        Ok(items.into_iter().map(Into::into).collect())
    }
}

/// Map a stored bookmark row to its bridge representation.
impl From<BookmarkRow> for BookmarkItem {
    fn from(row: BookmarkRow) -> Self {
        BookmarkItem {
            id: row.id,
            feed_id: row.feed_id,
            book_id: row.book_id,
            chapter_id: row.chapter_id,
            paragraph_id: ParagraphId::from_stored(row.paragraph_id),
            paragraph_name: row.paragraph_name,
            paragraph_preview: row.paragraph_preview,
            label: row.label,
            created_at_ms: row.created_at_ms,
        }
    }
}

/// Generate a simple unique ID (timestamp + random-ish suffix).
fn uuid() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    // Use a simple deterministic suffix based on the timestamp bits.
    // Not cryptographically random, but unique enough for bookmarks.
    let hi = (ts >> 32) as u32;
    let lo = ts as u32;
    format!("{hi:08x}-{lo:08x}")
}

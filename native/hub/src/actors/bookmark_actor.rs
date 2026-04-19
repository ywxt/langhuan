use std::path::Path;

use async_trait::async_trait;
use langhuan::bookmark::{Bookmark, BookmarkStore};
use messages::prelude::{Actor, Context, Handler};

use crate::api::types::{BookmarkItem, BridgeError, ParagraphId};
use crate::localize_error;

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
    store: Option<BookmarkStore>,
}

impl Actor for BookmarkActor {}

impl BookmarkActor {
    pub fn new() -> Self {
        Self { store: None }
    }

    async fn initialize_app_data_directory(&mut self, path: &str) -> Result<(), String> {
        let base_dir = Path::new(path);
        let bookmark_dir = bookmark_dir(base_dir);
        tracing::info!(path = %bookmark_dir.display(), "initializing bookmark storage");

        if let Err(e) = tokio::fs::create_dir_all(&bookmark_dir).await {
            return Err(e.to_string());
        }

        self.store = Some(
            BookmarkStore::open(bookmark_dir)
                .await
                .map_err(|e| localize_error(&e))?,
        );
        tracing::info!("bookmark storage initialized");
        Ok(())
    }
}

fn bookmark_dir(base_dir: &Path) -> std::path::PathBuf {
    base_dir.join("bookmarks")
}

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

// ---------------------------------------------------------------------------
// Handler impls
// ---------------------------------------------------------------------------

#[async_trait]
impl Handler<InitializeAppDataDirectory> for BookmarkActor {
    type Result = Result<(), String>;

    async fn handle(&mut self, msg: InitializeAppDataDirectory, _: &Context<Self>) -> Self::Result {
        self.initialize_app_data_directory(&msg.path).await
    }
}

#[async_trait]
impl Handler<AddBookmark> for BookmarkActor {
    type Result = Result<BookmarkItem, BridgeError>;

    async fn handle(&mut self, msg: AddBookmark, _: &Context<Self>) -> Self::Result {
        let store = self
            .store
            .as_mut()
            .ok_or_else(|| BridgeError::from(t!("error.app_data_dir_not_set").to_string()))?;

        let id = uuid();
        let bookmark = Bookmark {
            id: id.clone(),
            feed_id: msg.feed_id.clone(),
            book_id: msg.book_id.clone(),
            chapter_id: msg.chapter_id.clone(),
            paragraph_id: msg.paragraph_id.clone(),
            paragraph_name: msg.paragraph_name.clone(),
            paragraph_preview: msg.paragraph_preview.clone(),
            label: msg.label.clone(),
            created_at_ms: now_ms(),
        };

        let stored = store
            .add_bookmark(bookmark)
            .await
            .map_err(BridgeError::from)?;

        Ok(BookmarkItem {
            id: stored.id,
            feed_id: stored.feed_id,
            book_id: stored.book_id,
            chapter_id: stored.chapter_id,
            paragraph_id: ParagraphId::from_stored(stored.paragraph_id),
            paragraph_name: stored.paragraph_name,
            paragraph_preview: stored.paragraph_preview,
            label: stored.label,
            created_at_ms: stored.created_at_ms,
        })
    }
}

#[async_trait]
impl Handler<RemoveBookmark> for BookmarkActor {
    type Result = Result<bool, BridgeError>;

    async fn handle(&mut self, msg: RemoveBookmark, _: &Context<Self>) -> Self::Result {
        let store = self
            .store
            .as_mut()
            .ok_or_else(|| BridgeError::from(t!("error.app_data_dir_not_set").to_string()))?;

        store
            .remove_bookmark(&msg.id)
            .await
            .map_err(BridgeError::from)
    }
}

#[async_trait]
impl Handler<ListBookmarks> for BookmarkActor {
    type Result = Result<Vec<BookmarkItem>, BridgeError>;

    async fn handle(&mut self, msg: ListBookmarks, _: &Context<Self>) -> Self::Result {
        let store = self
            .store
            .as_ref()
            .ok_or_else(|| BridgeError::from(t!("error.app_data_dir_not_set").to_string()))?;

        let items = store.list_bookmarks(&msg.feed_id, &msg.book_id).await?;

        Ok(items
            .into_iter()
            .map(|b| BookmarkItem {
                id: b.id,
                feed_id: b.feed_id,
                book_id: b.book_id,
                chapter_id: b.chapter_id,
                paragraph_id: ParagraphId::from_stored(b.paragraph_id),
                paragraph_name: b.paragraph_name,
                paragraph_preview: b.paragraph_preview,
                label: b.label,
                created_at_ms: b.created_at_ms,
            })
            .collect())
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

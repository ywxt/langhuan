use async_trait::async_trait;
use langhuan::db::Db;
use langhuan::db::repo::BookmarkRow;
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
            id: next_bookmark_id(),
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
            move |repo| repo.add_bookmark(&row)
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
        db.write(move |repo| repo.remove_bookmark(&id))
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
            .call(move |repo| repo.list_bookmarks(&feed_id, &book_id))
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

/// Generate a unique bookmark id: nanosecond timestamp plus a process-wide
/// counter, so ids created within the same nanosecond still differ. Stable
/// across restarts (time moves forward) and cheap — no dependency on a
/// random source.
fn next_bookmark_id() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static SEQ: AtomicU64 = AtomicU64::new(0);
    let seq = SEQ.fetch_add(1, Ordering::Relaxed);
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{ts:016x}-{seq:04x}")
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::next_bookmark_id;

    /// The counter makes ids unique even when the clock does not move —
    /// regressions here would collide primary keys on bulk creation.
    #[test]
    fn bookmark_ids_are_unique() {
        let ids: HashSet<String> = (0..10_000).map(|_| next_bookmark_id()).collect();
        assert_eq!(ids.len(), 10_000);
    }
}

//! Read-only comments. Each call evaluates exactly one source page.
use super::types::BridgeError;
use crate::actors::{addresses, hub_db, registry_actor::GetFeed};
use langhuan::feed::comments::FeedComments;

pub struct CommentSupport {
    pub chapter: bool,
    pub paragraph: bool,
}
pub struct CommentItem {
    pub id: String,
    pub author_name: String,
    pub text: String,
    pub created_at_ms: Option<i64>,
    pub like_count: Option<u32>,
    pub has_replies: bool,
    pub reply_count: Option<u32>,
}
pub struct CommentPage {
    pub items: Vec<CommentItem>,
    pub next_cursor_json: Option<String>,
    pub total_count: Option<u32>,
}

/// The result and cancellation methods use shared access, so an in-flight
/// bridge result call cannot prevent another call from aborting the task.
pub struct CommentRequest {
    task: std::sync::Mutex<Option<tokio::task::JoinHandle<Result<CommentPage, BridgeError>>>>,
    abort: tokio::task::AbortHandle,
}

impl CommentRequest {
    pub async fn result(&self) -> Result<CommentPage, BridgeError> {
        let task = self
            .task
            .lock()
            .map_err(|_| BridgeError::from("comment request poisoned".to_owned()))?
            .take()
            .ok_or_else(|| BridgeError::from("comment result already consumed".to_owned()))?;
        task.await.map_err(|e| BridgeError::from(e.to_string()))?
    }
    pub fn cancel(&self) {
        self.abort.abort();
    }
}
impl Drop for CommentRequest {
    fn drop(&mut self) {
        self.abort.abort();
    }
}

pub async fn open_comments_page(
    feed_id: String,
    book_id: String,
    chapter_id: String,
    paragraph_id: Option<String>,
    parent_id: Option<String>,
    cursor_json: Option<String>,
) -> CommentRequest {
    let task = tokio::spawn(get_comments_page(
        feed_id,
        book_id,
        chapter_id,
        paragraph_id,
        parent_id,
        cursor_json,
    ));
    let abort = task.abort_handle();
    CommentRequest {
        task: std::sync::Mutex::new(Some(task)),
        abort,
    }
}

async fn enabled(feed_id: &str) -> Result<bool, BridgeError> {
    let id = feed_id.to_owned();
    Ok(hub_db()?
        .call(move |repo| repo.get_feed(&id))
        .await?
        .is_some_and(|row| row.enabled))
}

pub async fn comment_support(feed_id: String) -> Result<CommentSupport, BridgeError> {
    if !enabled(&feed_id).await? {
        return Ok(CommentSupport {
            chapter: false,
            paragraph: false,
        });
    }
    let result = addresses()?
        .registry
        .clone()
        .send(GetFeed { feed_id })
        .await?;
    let (chapter, paragraph) = result
        .map(|feed| feed.comment_support())
        .unwrap_or((false, false));
    Ok(CommentSupport { chapter, paragraph })
}

pub async fn get_comments_page(
    feed_id: String,
    book_id: String,
    chapter_id: String,
    paragraph_id: Option<String>,
    parent_id: Option<String>,
    cursor_json: Option<String>,
) -> Result<CommentPage, BridgeError> {
    static PERMITS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(4);
    let _permit = PERMITS
        .acquire()
        .await
        .map_err(|e| BridgeError::from(e.to_string()))?;
    if !enabled(&feed_id).await? {
        return Err(BridgeError::from(
            "feed is disabled or unavailable".to_owned(),
        ));
    }
    if cursor_json.as_ref().is_some_and(|v| v.len() > 4096) {
        return Err(BridgeError::from("comment cursor exceeds limit".to_owned()));
    }
    let cursor = cursor_json
        .map(|s| serde_json::from_str(&s))
        .transpose()
        .map_err(|e| BridgeError::from(e.to_string()))?
        .unwrap_or(serde_json::Value::Null);
    let feed = addresses()?
        .registry
        .clone()
        .send(GetFeed { feed_id })
        .await?
        .map_err(|e| BridgeError::from(e.to_string()))?;
    let page = feed
        .comments_page(
            &langhuan::feed::comments::CommentsQuery {
                book_id,
                chapter_id,
                paragraph_id,
                parent_id,
            },
            cursor,
        )
        .await?;
    Ok(CommentPage {
        items: page
            .items
            .into_iter()
            .map(|c| CommentItem {
                id: c.id,
                author_name: c.author.name,
                text: c.text,
                created_at_ms: c.created_at_ms,
                like_count: c.like_count,
                has_replies: c.replies.is_some(),
                reply_count: c.replies.and_then(|r| r.total_count),
            })
            .collect(),
        next_cursor_json: page.next_cursor.map(|v| v.to_string()),
        total_count: page.total_count,
    })
}

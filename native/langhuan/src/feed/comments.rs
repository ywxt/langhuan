//! Read-only, explicitly paged source comments.
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommentAuthor {
    pub name: String,
    pub avatar_url: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommentReplies {
    pub total_count: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Comment {
    pub id: String,
    pub author: CommentAuthor,
    pub text: String,
    pub created_at_ms: Option<i64>,
    pub like_count: Option<u32>,
    pub replies: Option<CommentReplies>,
    pub source_url: Option<String>,
}

#[derive(Debug)]
pub struct CommentPage {
    pub items: Vec<Comment>,
    pub next_cursor: Option<Value>,
    pub total_count: Option<u32>,
}

pub struct CommentsQuery {
    pub book_id: String,
    pub chapter_id: String,
    pub paragraph_id: Option<String>,
    pub parent_id: Option<String>,
}

/// Optional, read-only source extension. Pages are explicit so callers retain
/// independent chapter, paragraph and reply cursors.
pub trait FeedComments: Send + Sync {
    fn comment_support(&self) -> (bool, bool);
    fn comments_page(
        &self,
        query: &CommentsQuery,
        cursor: Value,
    ) -> impl Future<Output = crate::error::Result<CommentPage>> + Send;
}

impl FeedComments for crate::script::js::JsFeed {
    fn comment_support(&self) -> (bool, bool) {
        self.comment_support()
    }
    async fn comments_page(
        &self,
        query: &CommentsQuery,
        cursor: Value,
    ) -> crate::error::Result<CommentPage> {
        self.comments_page(query, cursor).await
    }
}

impl<F: super::Feed + FeedComments> FeedComments for crate::cache::CachedFeed<F> {
    fn comment_support(&self) -> (bool, bool) {
        self.inner().comment_support()
    }
    async fn comments_page(
        &self,
        query: &CommentsQuery,
        cursor: Value,
    ) -> crate::error::Result<CommentPage> {
        self.inner().comments_page(query, cursor).await
    }
}

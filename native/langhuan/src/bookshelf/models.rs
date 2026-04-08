use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct BookIdentity {
    pub feed_id: String,
    pub source_book_id: String,
}

impl BookIdentity {
    #[must_use]
    pub fn stable_id(&self) -> String {
        format!("{}:{}", self.feed_id, self.source_book_id)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookshelfEntry {
    pub identity: BookIdentity,
    pub added_at_unix_ms: i64,
}

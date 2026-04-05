use serde::{Deserialize, Serialize};

use crate::cache::CACHE_SCHEMA_VERSION;

/// Reading progress entry for a feed + book pair.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReadingProgress {
    pub feed_id: String,
    pub book_id: String,
    pub chapter_id: String,
    pub paragraph_index: usize,
    pub updated_at_ms: i64,
}

/// File format for reading progress persistence.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReadingProgressFile {
    pub schema_version: u32,
    pub entries: Vec<ReadingProgress>,
}

impl Default for ReadingProgressFile {
    fn default() -> Self {
        Self {
            schema_version: CACHE_SCHEMA_VERSION,
            entries: Vec::new(),
        }
    }
}

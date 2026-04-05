use serde::{Deserialize, Serialize};

use crate::model::BookInfo;
use crate::model::ChapterInfo;
use crate::model::Paragraph;

pub const CACHE_SCHEMA_VERSION: u32 = 1;

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Cached chapter list with metadata.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChapterListCacheEntry {
    pub feed_id: String,
    pub book_id: String,
    pub chapters: Vec<ChapterInfo>,
    pub cached_at_ms: i64,
    pub schema_version: u32,
}

impl ChapterListCacheEntry {
    /// Create a new chapter-list cache entry with current timestamp.
    pub fn new(feed_id: String, book_id: String, chapters: Vec<ChapterInfo>) -> Self {
        Self {
            feed_id,
            book_id,
            chapters,
            cached_at_ms: now_ms(),
            schema_version: CACHE_SCHEMA_VERSION,
        }
    }
}

/// Cached chapter content with metadata.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChapterCacheEntry {
    pub feed_id: String,
    pub book_id: String,
    pub chapter_id: String,
    pub paragraphs: Vec<Paragraph>,
    pub cached_at_ms: i64,
    pub schema_version: u32,
}

impl ChapterCacheEntry {
    /// Create a new chapter-content cache entry with current timestamp.
    pub fn new(
        feed_id: String,
        book_id: String,
        chapter_id: String,
        paragraphs: Vec<Paragraph>,
    ) -> Self {
        Self {
            feed_id,
            book_id,
            chapter_id,
            paragraphs,
            cached_at_ms: now_ms(),
            schema_version: CACHE_SCHEMA_VERSION,
        }
    }
}

/// Cached book info with metadata.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookInfoCacheEntry {
    pub feed_id: String,
    pub book_id: String,
    pub book_info: BookInfo,
    pub cached_at_ms: i64,
    pub schema_version: u32,
}

impl BookInfoCacheEntry {
    /// Create a new book-info cache entry with current timestamp.
    pub fn new(feed_id: String, book_id: String, book_info: BookInfo) -> Self {
        Self {
            feed_id,
            book_id,
            book_info,
            cached_at_ms: now_ms(),
            schema_version: CACHE_SCHEMA_VERSION,
        }
    }
}

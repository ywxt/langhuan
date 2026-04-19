use super::types::{BridgeError, ParagraphId, ReadingProgressItem};
use crate::actors::{
    addresses,
    reading_progress_actor::{GetReadingProgress, SetReadingProgress},
};

pub async fn get_reading_progress(
    feed_id: String,
    book_id: String,
) -> Result<Option<ReadingProgressItem>, BridgeError> {
    addresses()?
        .reading_progress
        .clone()
        .send(GetReadingProgress { feed_id, book_id })
        .await?
}

pub async fn set_reading_progress(
    feed_id: String,
    book_id: String,
    chapter_id: String,
    paragraph_id: ParagraphId,
    updated_at_ms: i64,
) -> Result<(), BridgeError> {
    addresses()?
        .reading_progress
        .clone()
        .send(SetReadingProgress {
            feed_id,
            book_id,
            chapter_id,
            paragraph_id: paragraph_id.to_string_lossy(),
            updated_at_ms,
        })
        .await?
}

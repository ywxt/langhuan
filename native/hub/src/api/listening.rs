//! Local TTS resume positions, separate from reading progress.
use super::types::BridgeError;
use crate::actors::hub_db;
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize)]
pub struct ListeningPosition {
    pub chapter_id: String,
    pub paragraph_id: String,
}

pub async fn get_listening_position(
    feed_id: String,
    book_id: String,
) -> Result<Option<ListeningPosition>, BridgeError> {
    let stored = hub_db()?
        .call(move |repo| repo.get_listening_position(&feed_id, &book_id))
        .await?;
    stored
        .map(|v| serde_json::from_str(&v).map_err(|e| BridgeError::from(e.to_string())))
        .transpose()
}

pub async fn save_listening_position(
    feed_id: String,
    book_id: String,
    position: ListeningPosition,
) -> Result<(), BridgeError> {
    if position.chapter_id.is_empty() || position.paragraph_id.len() > 8192 {
        return Err(BridgeError::from("invalid listening position".to_owned()));
    }
    let value = serde_json::to_string(&position).map_err(|e| BridgeError::from(e.to_string()))?;
    hub_db()?
        .write(move |repo| {
            repo.set_listening_position(&feed_id, &book_id, &value)?;
            repo.set_progress(
                &feed_id,
                &book_id,
                &position.chapter_id,
                &position.paragraph_id,
                0,
                langhuan::db::now_ms(),
            )
        })
        .await
        .map_err(Into::into)
}

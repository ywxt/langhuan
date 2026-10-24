use crate::actors::addresses;
use crate::actors::conversion_actor::SetConversionMode;

pub use super::types::{BridgeError, ChineseConversionMode};

/// Set the Chinese text conversion mode.
///
/// This affects all subsequent paragraph streams opened via
/// [`open_paragraphs_stream`](super::feed_stream::open_paragraphs_stream).
/// Already-open streams are not retroactively changed.
pub async fn set_chinese_conversion_mode(mode: ChineseConversionMode) -> Result<(), BridgeError> {
    addresses()?
        .conversion
        .clone()
        .send(SetConversionMode { mode })
        .await
        .map_err(BridgeError::from)?;
    Ok(())
}

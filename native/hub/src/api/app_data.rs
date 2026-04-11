use super::types::BridgeError;
use crate::actors::{addresses, app_data_actor::SetAppDataDirectory};

/// Initialize the app data directory. Returns the number of feeds loaded.
pub async fn set_app_data_directory(path: String) -> Result<u32, BridgeError> {
    let result = addresses()?
        .app_data
        .clone()
        .send(SetAppDataDirectory { path })
        .await?;
    Ok(result?.feed_count)
}

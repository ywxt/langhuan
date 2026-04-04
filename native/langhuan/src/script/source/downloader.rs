//! Utilities for downloading feed scripts from a remote URL.

use crate::error::Result;

/// Download a Lua feed script from `url` and return its content as a string.
///
/// Uses a one-off [`reqwest::Client`] with default settings.  The caller is
/// responsible for validating the returned content by passing it to
/// [`crate::script::meta::parse_meta`].
///
/// # Errors
/// - [`crate::error::Error::Http`] if the request fails or the server returns
///   a non-2xx status.
pub async fn download_script(url: &str) -> Result<String> {
    tracing::debug!(url = %url, "downloading feed script");
    let client = reqwest::Client::new();
    let content = client
        .get(url)
        .send()
        .await?
        .error_for_status()?
        .text()
        .await?;
    tracing::info!(url = %url, content_len = content.len(), "feed script downloaded");
    Ok(content)
}

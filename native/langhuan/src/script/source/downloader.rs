//! Utilities for downloading feed scripts from a remote URL.

use std::time::Duration;

use crate::error::{Error, Result};
use crate::http::shared_client;

/// Total budget for one script download: connection, request, and body.
///
/// Unlike sandboxed feed requests — where [`crate::http::execute`] takes a
/// caller-supplied budget — a script download is always user-facing, so the
/// budget is fixed here.
pub const DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(30);

/// Upper bound on a downloaded feed script.
///
/// Real feed scripts are tens of kilobytes; anything larger is either
/// hostile or not a script. The cap is enforced while streaming (and on the
/// declared `Content-Length` before a single body byte is read), because the
/// preview payload carries the full script text to Dart for pre-install
/// auditing — an unbounded download would become an unbounded UI payload.
pub const MAX_SCRIPT_BYTES: usize = 2 * 1024 * 1024;

/// Download a JavaScript feed from `url` and return its content as a string.
///
/// Uses the shared cookie-free client from [`shared_client`].  The caller is
/// responsible for validating the returned content by passing it to
/// [`crate::script::meta::parse_meta`].
///
/// # Errors
/// - [`crate::error::Error::Http`] if the request fails or the server returns
///   a non-2xx status (including an elapsed [`DOWNLOAD_TIMEOUT`] budget).
/// - [`Error::Script`] with [`crate::error::ScriptError::TooLarge`] if the
///   script exceeds [`MAX_SCRIPT_BYTES`].
pub async fn download_script(url: &str) -> Result<String> {
    download_script_with_budget(url, DOWNLOAD_TIMEOUT).await
}

/// Budgeted download core (tests pass a tight budget to keep stalls fast).
async fn download_script_with_budget(url: &str, timeout: Duration) -> Result<String> {
    tracing::debug!(url = %url, "downloading feed script");
    let client = shared_client();
    let mut response = client
        .get(url)
        .timeout(timeout)
        .send()
        .await?
        .error_for_status()?;

    // A declared length lets oversized scripts be rejected before their
    // body is read at all.
    if response
        .content_length()
        .is_some_and(|len| len as usize > MAX_SCRIPT_BYTES)
    {
        tracing::warn!(url = %url, "feed script exceeds size cap");
        return Err(Error::script_too_large(MAX_SCRIPT_BYTES));
    }

    let mut body: Vec<u8> = Vec::new();
    while let Some(chunk) = response.chunk().await? {
        if body.len() + chunk.len() > MAX_SCRIPT_BYTES {
            tracing::warn!(url = %url, "feed script exceeds size cap mid-stream");
            return Err(Error::script_too_large(MAX_SCRIPT_BYTES));
        }
        body.extend_from_slice(&chunk);
    }

    tracing::info!(url = %url, content_len = body.len(), "feed script downloaded");
    // Lossy decode matches reqwest's `text()` semantics.
    Ok(String::from_utf8_lossy(&body).into_owned())
}

#[cfg(test)]
mod tests {
    use std::io::{Read, Write};
    use std::time::Instant;

    use super::*;

    /// Serve one raw HTTP response on a background thread, then close the
    /// connection; returns the URL to request.
    fn serve_once(response: String) -> String {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind test listener");
        let addr = listener.local_addr().expect("listener address");
        std::thread::spawn(move || {
            if let Ok((mut socket, _)) = listener.accept() {
                // Drain the request first: closing a socket with unread
                // pending bytes makes the OS send RST instead of FIN, which
                // would truncate the response body for the client.
                let mut buf = [0u8; 4096];
                while let Ok(n) = socket.read(&mut buf) {
                    if n == 0 || buf[..n].windows(4).any(|w| w == b"\r\n\r\n") {
                        break;
                    }
                }
                let _ = socket.write_all(response.as_bytes());
                let _ = socket.flush();
                let _ = socket.shutdown(std::net::Shutdown::Write);
            }
        });
        format!("http://{addr}/script.js")
    }

    #[tokio::test]
    async fn downloads_a_small_script() {
        let url = serve_once("HTTP/1.1 200 OK\r\n\r\n// ==Feed==\n".to_owned());
        let content = download_script(&url).await.expect("small script downloads");
        assert_eq!(content, "// ==Feed==\n");
    }

    #[tokio::test]
    async fn rejects_oversized_content_length_without_reading_the_body() {
        let url = serve_once(format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n",
            10 * MAX_SCRIPT_BYTES
        ));
        let error = download_script(&url)
            .await
            .expect_err("an oversized script must be rejected");
        assert!(
            matches!(
                error,
                Error::Script(crate::error::ScriptError::TooLarge { .. })
            ),
            "not a too-large error: {error}"
        );
    }

    #[tokio::test]
    async fn rejects_an_oversized_streamed_body_without_content_length() {
        // No Content-Length: the cap has to hold while streaming.
        let body = "a".repeat(MAX_SCRIPT_BYTES + 1);
        let url = serve_once(format!("HTTP/1.1 200 OK\r\n\r\n{body}"));
        let error = download_script(&url)
            .await
            .expect_err("a streamed oversize must be rejected");
        assert!(
            matches!(
                error,
                Error::Script(crate::error::ScriptError::TooLarge { .. })
            ),
            "not a too-large error: {error}"
        );
    }

    #[tokio::test]
    async fn a_stalled_server_trips_the_budget() {
        // A server that accepts the connection and never writes a byte —
        // without a budget this download would hang forever.
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind stall listener");
        let addr = listener.local_addr().expect("stall listener address");
        std::thread::spawn(move || {
            let _socket = listener.accept().expect("accept stalled connection");
            std::thread::park();
        });

        let start = Instant::now();
        let error = download_script_with_budget(
            &format!("http://{addr}/stall"),
            Duration::from_millis(300),
        )
        .await
        .expect_err("a stalled server must trip the download budget");
        assert!(
            matches!(error, Error::Http(ref e) if e.is_timeout()),
            "not a timeout error: {error}"
        );
        assert!(
            start.elapsed() < Duration::from_secs(5),
            "budget elapse took {:?}",
            start.elapsed()
        );
    }
}

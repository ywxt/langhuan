//! HTTP types and execution for Langhuan feed scripts.
//!
//! This module owns the [`HttpRequest`], [`HttpResponse`], and [`HttpBody`]
//! data types as well as the runtime helpers that execute requests and convert
//! them to/from sandboxed JavaScript values.

use std::collections::HashSet;
use std::fmt;
use std::str::FromStr;
use std::sync::Arc;
use std::time::{Duration, Instant};

use bytes::Bytes;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use tokio_stream::StreamExt;

use crate::error::Result;

// ---------------------------------------------------------------------------
// Client construction
// ---------------------------------------------------------------------------

/// Build a free-following cookie-free HTTP client.
///
/// TLS is verified against the Mozilla root set compiled into the binary on
/// every platform. reqwest's default root source — `rustls-platform-verifier`
/// — reads the platform trust store instead, which on Android drags in JNI
/// glue: the crate's `jni` feature, an exported JNI symbol in `hub`, and a
/// manual initialization call from `MainActivity`. Bundled roots keep the
/// whole TLS stack pure Rust with zero platform integration. The tradeoff:
/// user-installed CA certificates (proxy or enterprise) are not trusted.
///
/// Redirects are followed without a domain check — this client is for
/// downloads that have no allowlist yet (feed scripts) and for tests; feed
/// requests and covers go through [`new_feed_client`] instead.
pub fn new_client() -> Client {
    Client::builder()
        .tls_backend_preconfigured(build_tls_config())
        .redirect(redirect_policy(None))
        .build()
        .expect("failed to build HTTP client")
}

/// The HTTP client belonging to one feed.
///
/// Unlike the free-following [`new_client`], every redirect hop of a request
/// made through this client is re-checked against the feed's
/// `access_domains`: a hop outside them stops the chain and surfaces as the
/// 3xx response, which [`execute`] maps to a domain-not-allowed error. Each
/// feed owns its client, so no cross-feed state (task-locals, globals) is
/// involved.
pub fn new_feed_client(access_domains: &HashSet<String>) -> Client {
    Client::builder()
        .tls_backend_preconfigured(build_tls_config())
        .redirect(redirect_policy(Some(Arc::new(access_domains.clone()))))
        .build()
        .expect("failed to build HTTP client")
}

/// The preconfigured rustls backend shared by every client built here.
fn build_tls_config() -> rustls::ClientConfig {
    let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
    let roots = rustls::RootCertStore {
        roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
    };
    let mut tls = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .expect("safe default TLS protocol versions")
        .with_root_certificates(roots)
        .with_no_client_auth();
    // reqwest never touches a preconfigured TLS config, so ALPN must be set
    // here for HTTP/2 to remain negotiable.
    tls.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
    tls
}

// ---------------------------------------------------------------------------
// Redirect policy
// ---------------------------------------------------------------------------

/// Redirect hops followed per request — reqwest's `Policy::limited` default,
/// restated because custom policies do not inherit it.
const MAX_REDIRECTS: usize = 10;

/// The redirect policy installed on every client built here.
///
/// `allowlist` bounds the redirect hops: a hop outside it is stopped and
/// returned as the 3xx response, which the caller maps to a domain error.
/// `None` follows hops without a domain check, exactly like the reqwest
/// default (feed script downloads, tests). The hop cap applies to both, and
/// sensitive header stripping across hosts is unaffected.
fn redirect_policy(allowlist: Option<Arc<HashSet<String>>>) -> reqwest::redirect::Policy {
    reqwest::redirect::Policy::custom(move |attempt| {
        // Restate the default hop cap custom policies don't inherit.
        if attempt.previous().len() > MAX_REDIRECTS {
            return attempt.error("too many redirects");
        }
        match &allowlist {
            Some(allowlist) if !domain_allowed(attempt.url().as_str(), allowlist) => attempt.stop(),
            _ => attempt.follow(),
        }
    })
}

/// The absolute target of a followable 3xx response — the `Location` header
/// resolved against the response URL. `None` when the response carries none,
/// in which case reqwest hands it through as a terminal response.
fn redirect_target(response: &reqwest::Response) -> Option<String> {
    let location = response
        .headers()
        .get(reqwest::header::LOCATION)?
        .to_str()
        .ok()?;
    let resolved = reqwest::Url::parse(location)
        .or_else(|_| response.url().join(location))
        .ok()?;
    Some(resolved.to_string())
}

// ---------------------------------------------------------------------------
// HttpBody
// ---------------------------------------------------------------------------

/// A body carried by either an HTTP request or an HTTP response.
///
/// Raw bytes in native code; JavaScript receives Uint8Array and explicitly
/// decodes text through langhuan:encoding.
#[derive(Debug, Clone)]
pub struct HttpBody(pub Bytes);

impl HttpBody {
    /// Construct an [`HttpBody`] from a UTF-8 [`String`].
    pub fn from_string(s: String) -> Self {
        Self(Bytes::from(s))
    }

    /// Decode this body as UTF-8 text.
    ///
    /// Returns an error if the body contains invalid UTF-8.
    pub fn as_str(&self) -> std::result::Result<&str, std::str::Utf8Error> {
        std::str::from_utf8(&self.0)
    }
}

impl From<String> for HttpBody {
    fn from(value: String) -> Self {
        Self::from_string(value)
    }
}

impl From<&str> for HttpBody {
    fn from(value: &str) -> Self {
        Self(Bytes::copy_from_slice(value.as_bytes()))
    }
}

impl Default for HttpBody {
    fn default() -> Self {
        Self(Bytes::new())
    }
}

impl fmt::Display for HttpBody {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.as_str() {
            Ok(s) => f.write_str(s),
            Err(_) => Err(fmt::Error),
        }
    }
}

impl FromStr for HttpBody {
    type Err = std::convert::Infallible;

    fn from_str(s: &str) -> std::result::Result<Self, Self::Err> {
        Ok(Self::from(s))
    }
}

impl Serialize for HttpBody {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_bytes(&self.0)
    }
}

impl<'de> Deserialize<'de> for HttpBody {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        struct HttpBodyVisitor;

        impl<'de> serde::de::Visitor<'de> for HttpBodyVisitor {
            type Value = HttpBody;

            fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
                formatter.write_str("a byte array for HTTP body")
            }

            fn visit_bytes<E>(self, v: &[u8]) -> std::result::Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                Ok(HttpBody(Bytes::copy_from_slice(v)))
            }

            fn visit_byte_buf<E>(self, v: Vec<u8>) -> std::result::Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                Ok(HttpBody(Bytes::from(v)))
            }
        }

        deserializer.deserialize_bytes(HttpBodyVisitor)
    }
}

// ---------------------------------------------------------------------------
// HttpRequest
// ---------------------------------------------------------------------------

/// An HTTP request descriptor constructed by a JavaScript feed.
///
/// Reducers return this JSON shape. Rust validates it and executes the actual
/// HTTP call outside the sandbox.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HttpRequest {
    /// The full target URL, including any query string.
    pub url: String,
    /// HTTP method (GET, POST, …). Defaults to `"GET"`.
    #[serde(default = "default_method")]
    pub method: String,
    /// Additional HTTP headers.
    ///
    /// Scripts provide a string-keyed object. Response headers separately
    /// use pairs to retain repeated Set-Cookie fields.
    #[serde(
        default,
        serialize_with = "serialize_headers",
        deserialize_with = "deserialize_headers"
    )]
    pub headers: Vec<(String, String)>,
    /// An optional request body (for POST/PUT), as raw bytes.
    #[serde(default)]
    pub body: Option<HttpBody>,
}

fn default_method() -> String {
    "GET".to_owned()
}

/// Serialize request headers as a map. This is important for the JavaScript auth
/// hook: feeds naturally patch headers with
/// `request.headers["Authorization"] = ...`. Serializing the Rust vector as
/// an array would make ordinary property mutation awkward.
fn serialize_headers<S>(
    headers: &[(String, String)],
    serializer: S,
) -> std::result::Result<S::Ok, S::Error>
where
    S: serde::Serializer,
{
    use serde::ser::SerializeMap;

    let mut map = serializer.serialize_map(Some(headers.len()))?;
    for (name, value) in headers {
        map.serialize_entry(name, value)?;
    }
    map.end()
}

/// Request headers have exactly one external shape: a string map.
fn deserialize_headers<'de, D>(
    deserializer: D,
) -> std::result::Result<Vec<(String, String)>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let headers = std::collections::BTreeMap::<String, String>::deserialize(deserializer)?;
    Ok(headers.into_iter().collect())
}

// ---------------------------------------------------------------------------
// HttpResponse
// ---------------------------------------------------------------------------

/// An HTTP response passed from Rust into a JavaScript reducer.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HttpResponse {
    /// HTTP status code.
    pub status: u16,
    /// Response headers.
    pub headers: Vec<(String, String)>,
    /// The response body as raw bytes.
    pub body: HttpBody,
    /// The final URL after any redirects.
    pub url: String,
}

// ---------------------------------------------------------------------------
// HTTP execution
// ---------------------------------------------------------------------------

/// Upper bound for an HTTP response body buffered for a feed script.
///
/// Script responses are handed to the sandbox as one `Uint8Array`, so a
/// runaway page (or a lying content-length) must not be buffered in full.
/// Cover downloads share the same bound.
pub(crate) const MAX_RESPONSE_BYTES: usize = 5 * 1024 * 1024;

/// Why a size-capped body read failed.
enum BodyReadError {
    Transport(reqwest::Error),
    TooLarge,
}

/// Stream the response body into memory, aborting once it would exceed
/// [`MAX_RESPONSE_BYTES`] — complementing the content-length pre-check for
/// servers that lie about the size.
async fn read_response_body(
    response: reqwest::Response,
) -> std::result::Result<Bytes, BodyReadError> {
    let mut stream = response.bytes_stream();
    let mut buf: Vec<u8> = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(BodyReadError::Transport)?;
        if buf.len() + chunk.len() > MAX_RESPONSE_BYTES {
            return Err(BodyReadError::TooLarge);
        }
        buf.extend_from_slice(&chunk);
    }
    Ok(Bytes::from(buf))
}

/// Execute an HTTP request described by an [`HttpRequest`] and return an
/// [`HttpResponse`].
///
/// `feed_id` and `access_domains` are used for domain allowlist enforcement
/// and tracing: the initial URL must be allowed. `client` should come from
/// [`new_feed_client`] so redirect hops are re-checked against the same
/// allowlist — a hop outside it stops the chain and surfaces here as a
/// domain-not-allowed error. The response body is refused beyond
/// [`MAX_RESPONSE_BYTES`].
///
/// `timeout` is the total budget for the attempt — connection
/// establishment, sending the request, and reading the response body —
/// applied as a per-request timeout so an elapsed budget surfaces as an
/// ordinary reqwest timeout error. The budget stays a caller parameter
/// because feed requests and bulk downloads have different needs. When a
/// trace recorder is active for the current task (developer tools only — see
/// [`crate::trace`]), the request and its outcome are recorded, including
/// requests blocked by the allowlist.
pub async fn execute(
    client: &Client,
    feed_id: &str,
    access_domains: &HashSet<String>,
    req: &HttpRequest,
    timeout: Duration,
) -> Result<HttpResponse> {
    let request_started = Instant::now();
    // Developer tools: while a trace recorder is active for this task,
    // report this request's outcome to it. Outside a debug run this is one
    // task-local lookup and nothing else.
    let trace = crate::trace::active();
    let start = trace.is_some().then(Instant::now);

    // Enforce access_domains before making any network call.
    if !domain_allowed(&req.url, access_domains) {
        tracing::warn!(
            feed_id = %feed_id,
            url = %req.url,
            "blocked request by access_domains"
        );
        if let Some(trace) = &trace {
            trace.record_blocked(req, start);
        }
        return Err(crate::error::Error::domain_not_allowed(
            req.url.clone(),
            access_domains.clone(),
        ));
    }

    let method = req
        .method
        .parse::<reqwest::Method>()
        .map_err(|_| crate::error::Error::invalid_feed("invalid HTTP request method"))?;
    tracing::debug!(
        feed_id = %feed_id,
        method = %method,
        url = %req.url,
        "sending HTTP request"
    );
    let mut builder = client.request(method, &req.url).timeout(timeout);

    for (key, value) in &req.headers {
        builder = builder.header(key.as_str(), value.as_str());
    }

    if let Some(body) = &req.body {
        builder = builder.body(body.0.clone());
    }

    let response = match builder.send().await {
        Ok(response) => response,
        Err(e) => {
            tracing::warn!(
                feed_id = %feed_id,
                url = %redact_url_secrets(&req.url),
                error = %e,
                "HTTP request failed"
            );
            if let Some(trace) = &trace {
                trace.record_send_error(req, start, &e);
            }
            return Err(e.into());
        }
    };

    let status = response.status().as_u16();
    let url = response.url().to_string();

    // A followable 3xx can only surface here when the client's redirect
    // policy stopped the chain: hop targets outside `access_domains` (the
    // initial URL passed the check above, and allowlisted hops are followed
    // transparently). Report it like an initial-URL block.
    if matches!(status, 301 | 302 | 303 | 307 | 308)
        && let Some(next) = redirect_target(&response)
    {
        tracing::warn!(
            feed_id = %feed_id,
            url = %redact_url_secrets(&next),
            "blocked request by access_domains (redirect hop)"
        );
        if let Some(trace) = &trace {
            trace.record_blocked(req, start);
        }
        return Err(crate::error::Error::domain_not_allowed(
            next,
            access_domains.clone(),
        ));
    }

    tracing::debug!(
        feed_id = %feed_id,
        status,
        url = %redact_url_secrets(&url),
        "received HTTP response"
    );

    // Refuse declared-oversized responses before streaming the body.
    if let Some(len) = response.content_length()
        && len as usize > MAX_RESPONSE_BYTES
    {
        tracing::warn!(
            feed_id = %feed_id,
            status,
            url = %redact_url_secrets(&url),
            length = len,
            "HTTP response exceeds size cap"
        );
        return Err(crate::error::Error::response_too_large(MAX_RESPONSE_BYTES));
    }

    let headers = collect_response_headers(response.headers());

    let body = match read_response_body(response).await {
        Ok(body) => body,
        Err(BodyReadError::TooLarge) => {
            tracing::warn!(
                feed_id = %feed_id,
                status,
                url = %redact_url_secrets(&url),
                "HTTP response exceeds size cap"
            );
            return Err(crate::error::Error::response_too_large(MAX_RESPONSE_BYTES));
        }
        Err(BodyReadError::Transport(e)) => {
            tracing::warn!(
                feed_id = %feed_id,
                status,
                url = %redact_url_secrets(&url),
                error = %e,
                "HTTP response body download failed"
            );
            if let Some(trace) = &trace {
                trace.record_body_error(req, status, &url, start, &e);
            }
            return Err(e.into());
        }
    };

    tracing::debug!(
        feed_id = %feed_id,
        status,
        url = %redact_url_secrets(&url),
        body_bytes = body.len(),
        elapsed_ms = request_started.elapsed().as_millis(),
        "HTTP request completed"
    );

    if let Some(trace) = &trace {
        trace.record_response(req, status, &url, &body, start);
    }

    Ok(HttpResponse {
        status,
        headers,
        body: HttpBody(body),
        url,
    })
}

/// Preserve every response header value, including repeated headers such as
/// `Set-Cookie`. `HeaderMap::iter` only exposes the first value for a name,
/// which silently discarded the remaining cookies required by authenticated
/// multi-step feeds.
fn collect_response_headers(headers: &reqwest::header::HeaderMap) -> Vec<(String, String)> {
    headers
        .keys()
        .flat_map(|name| {
            headers.get_all(name).iter().filter_map(move |value| {
                value
                    .to_str()
                    .ok()
                    .map(|value| (name.as_str().to_owned(), value.to_owned()))
            })
        })
        .collect()
}

/// Mask credential-like query values before a URL is logged or exposed by
/// developer traces. The real URL remains untouched for redirects and HTTP.
pub(crate) fn redact_url_secrets(url: &str) -> String {
    let Ok(mut parsed) = reqwest::Url::parse(url) else {
        return url.to_owned();
    };
    let pairs = parsed
        .query_pairs()
        .map(|(name, value)| {
            let lower = name.to_ascii_lowercase();
            let sensitive = ["token", "secret", "password", "authorization", "signature"]
                .iter()
                .any(|part| lower.contains(part));
            (
                name.into_owned(),
                if sensitive {
                    "<masked>".to_owned()
                } else {
                    value.into_owned()
                },
            )
        })
        .collect::<Vec<_>>();
    if pairs.is_empty() {
        return url.to_owned();
    }
    parsed.query_pairs_mut().clear().extend_pairs(pairs);
    parsed.to_string()
}

// ---------------------------------------------------------------------------
// Domain allowlist helper
// ---------------------------------------------------------------------------

/// Check whether the host of `url` is permitted by `access_domains`.
///
/// Entries are exact hostnames or leftmost-label wildcards such as
/// `*.example.com`. A wildcard matches one or more subdomain labels but never
/// the suffix itself, and matching always observes a DNS-label boundary.
/// Returns `true` if the host is allowed, `false` if the URL cannot be parsed
/// or the host is not in the list.
pub(crate) fn domain_allowed(url: &str, access_domains: &HashSet<String>) -> bool {
    let parsed = match reqwest::Url::parse(url) {
        Ok(u) => u,
        Err(_) => return false,
    };
    let host = match parsed.host_str() {
        Some(host) => host.trim_end_matches('.').to_ascii_lowercase(),
        None => return false,
    };
    access_domains.iter().any(|entry| {
        let entry = entry.to_ascii_lowercase();
        match entry.strip_prefix("*.") {
            Some(suffix) => {
                host.len() > suffix.len()
                    && host.ends_with(suffix)
                    && host.as_bytes().get(host.len() - suffix.len() - 1) == Some(&b'.')
            }
            None => host == entry,
        }
    })
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use std::collections::HashSet;
    use std::time::{Duration, Instant};

    use super::{
        HttpBody, HttpRequest, collect_response_headers, domain_allowed, execute, new_client,
        new_feed_client, redact_url_secrets,
    };

    #[test]
    fn http_body_to_string_roundtrip() {
        let src = "hello 世界";
        let body = HttpBody::from(src);
        assert_eq!(body.to_string(), src);
    }

    #[test]
    fn http_body_from_string_helper_works() {
        let body = HttpBody::from_string("payload".to_owned());
        assert_eq!(body.as_str().expect("valid utf-8"), "payload");
    }

    #[test]
    fn domain_allowlist_supports_boundary_safe_subdomain_wildcards() {
        let domains = HashSet::from([
            "api.example.com".to_owned(),
            "*.image.myqcloud.com".to_owned(),
        ]);

        assert!(domain_allowed("https://api.example.com/v1", &domains));
        assert!(domain_allowed(
            "https://imgservices-1.image.myqcloud.com/a.js",
            &domains
        ));
        assert!(domain_allowed(
            "https://a.b.image.myqcloud.com/a.js",
            &domains
        ));
        assert!(!domain_allowed("https://image.myqcloud.com/a.js", &domains));
        assert!(!domain_allowed(
            "https://image.myqcloud.com.evil.example/a.js",
            &domains
        ));
        assert!(!domain_allowed(
            "https://notimage.myqcloud.com/a.js",
            &domains
        ));
    }

    #[tokio::test]
    async fn execute_rejects_every_request_when_allowlist_is_empty() {
        let request = HttpRequest {
            url: "https://example.com/books".to_owned(),
            method: "GET".to_owned(),
            headers: Vec::new(),
            body: None,
        };

        let error = execute(
            &new_client(),
            "test",
            &HashSet::new(),
            &request,
            Duration::from_secs(1),
        )
        .await
        .expect_err("an empty allowlist must deny network access");

        let crate::error::Error::Script(crate::error::ScriptError::DomainNotAllowed {
            url,
            access_domains,
        }) = error
        else {
            panic!("expected a domain-not-allowed error, got: {error}");
        };
        assert_eq!(url, request.url);
        assert!(access_domains.is_empty());
    }

    #[test]
    fn http_body_from_str_works() {
        let body: HttpBody = "abc".parse().expect("infallible parse should succeed");
        assert_eq!(body.as_str().expect("valid utf-8"), "abc");
    }

    #[tokio::test]
    async fn execute_elapses_the_budget_against_a_stalled_server() {
        // A server that accepts the connection and never writes a byte — the
        // exact hang this budget exists to break. A plain std thread parks
        // while holding the socket open, so no tokio "net" feature is needed.
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind stall listener");
        let addr = listener.local_addr().expect("stall listener address");
        std::thread::spawn(move || {
            let _socket = listener.accept().expect("accept stalled connection");
            std::thread::park();
        });

        let request = HttpRequest {
            url: format!("http://{addr}/stall"),
            method: "GET".to_owned(),
            headers: Vec::new(),
            body: None,
        };
        let start = Instant::now();
        let error = execute(
            &new_client(),
            "test",
            &HashSet::from(["127.0.0.1".to_owned()]),
            &request,
            Duration::from_millis(300),
        )
        .await
        .expect_err("a stalled server must trip the request budget");

        // An elapsed budget is an ordinary reqwest timeout error: classified
        // transient, so the retry layer sees it and the operation can fail
        // honestly instead of hanging forever.
        let crate::error::Error::Http(reqwest_error) = &error else {
            panic!("expected an http error, got {error}");
        };
        assert!(reqwest_error.is_timeout(), "not a timeout error: {error}");
        assert!(
            error.is_retryable(),
            "a timeout must stay retryable: {error}"
        );
        assert!(
            start.elapsed() < Duration::from_secs(5),
            "budget elapse took {start:?}"
        );
    }

    #[test]
    fn response_headers_preserve_repeated_set_cookie_values() {
        let mut headers = reqwest::header::HeaderMap::new();
        headers.append("set-cookie", "session=one; Path=/".parse().unwrap());
        headers.append("set-cookie", "device=two; Path=/".parse().unwrap());

        let collected = collect_response_headers(&headers);
        assert_eq!(
            collected,
            [
                ("set-cookie".to_owned(), "session=one; Path=/".to_owned()),
                ("set-cookie".to_owned(), "device=two; Path=/".to_owned()),
            ]
        );
    }

    #[test]
    fn logged_urls_mask_secret_query_values() {
        let masked = redact_url_secrets(
            "https://example.com/chapter?bookId=42&_csrfToken=secret&signature=signed",
        );
        assert!(masked.contains("bookId=42"));
        assert!(!masked.contains("secret") && !masked.contains("signed"));
        assert_eq!(masked.matches("%3Cmasked%3E").count(), 2);
    }

    fn get_request(url: String) -> HttpRequest {
        HttpRequest {
            url,
            method: "GET".to_owned(),
            headers: Vec::new(),
            body: None,
        }
    }

    fn local_allowlist() -> HashSet<String> {
        HashSet::from(["127.0.0.1".to_owned()])
    }

    #[tokio::test]
    async fn execute_blocks_redirect_hops_outside_the_allowlist() {
        let mut server = mockito::Server::new_async().await;
        let _redirect = server
            .mock("GET", "/page")
            .with_status(302)
            .with_header("location", "https://evil.example/land")
            .create_async()
            .await;

        let error = execute(
            &new_feed_client(&local_allowlist()),
            "test",
            &local_allowlist(),
            &get_request(format!("{}/page", server.url())),
            Duration::from_secs(5),
        )
        .await
        .expect_err("a redirect hop outside the allowlist must be blocked");

        let crate::error::Error::Script(crate::error::ScriptError::DomainNotAllowed {
            url, ..
        }) = error
        else {
            panic!("expected a domain-not-allowed error, got: {error}");
        };
        assert_eq!(url, "https://evil.example/land");
    }

    #[tokio::test]
    async fn execute_follows_redirect_hops_inside_the_allowlist() {
        let mut server = mockito::Server::new_async().await;
        let _redirect = server
            .mock("GET", "/hop")
            .with_status(302)
            .with_header("location", "/land")
            .create_async()
            .await;
        let _landing = server
            .mock("GET", "/land")
            .with_status(200)
            .with_body("landed")
            .create_async()
            .await;

        let response = execute(
            &new_feed_client(&local_allowlist()),
            "test",
            &local_allowlist(),
            &get_request(format!("{}/hop", server.url())),
            Duration::from_secs(5),
        )
        .await
        .expect("an allowlisted redirect hop must be followed");

        assert_eq!(response.body.as_str(), Ok("landed"));
        assert!(
            response.url.ends_with("/land"),
            "final url: {}",
            response.url
        );
    }

    #[tokio::test]
    async fn execute_rejects_oversized_response_bodies() {
        let mut server = mockito::Server::new_async().await;
        let _huge = server
            .mock("GET", "/huge")
            .with_status(200)
            .with_header("content-type", "application/octet-stream")
            .with_body(vec![b'x'; super::MAX_RESPONSE_BYTES + 1])
            .create_async()
            .await;

        let error = execute(
            &new_feed_client(&local_allowlist()),
            "test",
            &local_allowlist(),
            &get_request(format!("{}/huge", server.url())),
            Duration::from_secs(30),
        )
        .await
        .expect_err("an oversized response body must be refused");

        let crate::error::Error::Script(crate::error::ScriptError::ResponseTooLarge { limit }) =
            error
        else {
            panic!("expected a response-too-large error, got: {error}");
        };
        assert_eq!(limit, super::MAX_RESPONSE_BYTES);
        assert!(!error.is_retryable());
    }

    #[tokio::test]
    async fn execute_stops_after_the_redirect_hop_limit() {
        let mut server = mockito::Server::new_async().await;
        let _loop = server
            .mock("GET", "/loop")
            .with_status(302)
            .with_header("location", "/loop")
            .create_async()
            .await;

        let error = execute(
            &new_feed_client(&local_allowlist()),
            "test",
            &local_allowlist(),
            &get_request(format!("{}/loop", server.url())),
            Duration::from_secs(10),
        )
        .await
        .expect_err("a redirect loop must be stopped by the hop limit");

        assert!(!error.is_retryable());
        assert!(
            format!("{error:?}").contains("too many redirects"),
            "unexpected error: {error:?}"
        );
    }
}

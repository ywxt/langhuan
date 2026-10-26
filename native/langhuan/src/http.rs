//! HTTP types and execution for Langhuan feed scripts.
//!
//! This module owns the [`HttpRequest`], [`HttpResponse`], and [`HttpBody`]
//! data types as well as the runtime helpers that execute requests and convert
//! them to/from Lua values.

use std::collections::{HashMap, HashSet};
use std::fmt;
use std::str::FromStr;
use std::sync::{Arc, LazyLock};
use std::time::Instant;

use bytes::Bytes;
use reqwest::Client;
use serde::{Deserialize, Serialize};

use crate::error::Result;

// ---------------------------------------------------------------------------
// Client construction
// ---------------------------------------------------------------------------

/// Build the HTTP client used across the app.
///
/// TLS is verified against the Mozilla root set compiled into the binary on
/// every platform. reqwest's default root source — `rustls-platform-verifier`
/// — reads the platform trust store instead, which on Android drags in JNI
/// glue: the crate's `jni` feature, an exported JNI symbol in `hub`, and a
/// manual initialization call from `MainActivity`. Bundled roots keep the
/// whole TLS stack pure Rust with zero platform integration. The tradeoff:
/// user-installed CA certificates (proxy or enterprise) are not trusted.
pub fn new_client() -> Client {
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
    Client::builder()
        .tls_backend_preconfigured(tls)
        .build()
        .expect("failed to build HTTP client")
}

/// The app-wide client for cookie-free downloads (covers, feed scripts).
///
/// Building a [`Client`] sets up a TLS config and a connection pool, so
/// callers that make occasional cookie-free downloads share this single
/// instance instead of constructing (and throwing away) their own. Callers
/// that need isolation — the script engine, which owns one client per
/// engine — keep building theirs with [`new_client`].
static SHARED_CLIENT: LazyLock<Client> = LazyLock::new(new_client);

/// Borrow the shared cookie-free HTTP client; see [`SHARED_CLIENT`].
pub fn shared_client() -> &'static Client {
    &SHARED_CLIENT
}

// ---------------------------------------------------------------------------
// HttpBody
// ---------------------------------------------------------------------------

/// A body carried by either an HTTP request or an HTTP response.
///
/// Raw bytes only — all encoding and decoding is the Lua script's responsibility.
/// On responses, Rust always delivers the raw bytes; Lua can call `json.decode`
/// or handle the string as needed.
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

/// An HTTP request descriptor constructed by a Lua feed script.
///
/// The Lua `*_request` functions return a table that is deserialized into this
/// struct. Rust then executes the actual HTTP call.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HttpRequest {
    /// The target URL.
    pub url: String,
    /// HTTP method (GET, POST, …). Defaults to `"GET"`.
    #[serde(default = "default_method")]
    pub method: String,
    /// Query parameters appended to the URL.
    #[serde(default)]
    pub params: HashMap<String, String>,
    /// Additional HTTP headers.
    ///
    /// Lua scripts may provide headers as either:
    /// - A map: `{ ["Content-Type"] = "application/json" }`
    /// - An array of pairs: `{ {"Content-Type", "application/json"} }`
    ///
    /// Both forms are accepted and normalised to `Vec<(String, String)>`.
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

/// Serialize request headers as a map. This is important for the Lua auth
/// hook: feeds naturally patch headers with
/// `request.headers["Authorization"] = ...`. Serializing the Rust vector as
/// an array would create a mixed Lua table, whose string keys are lost when it
/// is deserialized through the sequence representation.
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

/// Deserialize HTTP headers from either a map or an array of pairs.
///
/// Lua scripts commonly express headers as a string-keyed table:
///
/// ```lua
/// headers = { ["Content-Type"] = "text/html" }
/// ```
///
/// but some older scripts may use an array of two-element arrays:
///
/// ```lua
/// headers = { {"Content-Type", "text/html"} }
/// ```
///
/// This custom deserializer accepts both forms.
fn deserialize_headers<'de, D>(
    deserializer: D,
) -> std::result::Result<Vec<(String, String)>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::de::{self, MapAccess, SeqAccess, Visitor};

    struct HeadersVisitor;

    impl<'de> Visitor<'de> for HeadersVisitor {
        type Value = Vec<(String, String)>;

        fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
            f.write_str("a map of header name→value or an array of [name, value] pairs")
        }

        // Map form: { ["Key"] = "Value", ... }
        fn visit_map<A>(self, mut map: A) -> std::result::Result<Self::Value, A::Error>
        where
            A: MapAccess<'de>,
        {
            let mut headers = Vec::new();
            while let Some((key, value)) = map.next_entry::<String, String>()? {
                headers.push((key, value));
            }
            Ok(headers)
        }

        // Array-of-pairs form: { {"Key", "Value"}, ... }
        fn visit_seq<A>(self, mut seq: A) -> std::result::Result<Self::Value, A::Error>
        where
            A: SeqAccess<'de>,
        {
            let mut headers = Vec::new();
            while let Some(pair) = seq.next_element::<(String, String)>()? {
                headers.push(pair);
            }
            Ok(headers)
        }

        // `nil` / absent → empty
        fn visit_unit<E>(self) -> std::result::Result<Self::Value, E>
        where
            E: de::Error,
        {
            Ok(Vec::new())
        }

        fn visit_none<E>(self) -> std::result::Result<Self::Value, E>
        where
            E: de::Error,
        {
            Ok(Vec::new())
        }
    }

    deserializer.deserialize_any(HeadersVisitor)
}

// ---------------------------------------------------------------------------
// HttpResponse
// ---------------------------------------------------------------------------

/// An HTTP response passed from Rust into a Lua `parse_*` function.
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

/// Execute an HTTP request described by an [`HttpRequest`] and return an
/// [`HttpResponse`].
///
/// `feed_id` and `access_domains` are used for domain allowlist enforcement
/// and tracing. When a trace recorder is active for the current task
/// (developer tools only — see [`crate::trace`]), the request and its
/// outcome are recorded, including requests blocked by the allowlist.
pub async fn execute(
    client: &Client,
    feed_id: &str,
    access_domains: &HashSet<String>,
    req: &HttpRequest,
) -> Result<HttpResponse> {
    // Developer tools: while a trace recorder is active for this task,
    // report this request's outcome to it. Outside a debug run this is one
    // task-local lookup and nothing else.
    let trace = crate::trace::active();
    let start = trace.is_some().then(Instant::now);

    // Enforce access_domains before making any network call.
    if !access_domains.is_empty() && !domain_allowed(&req.url, access_domains) {
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

    let method = req.method.parse().unwrap_or(reqwest::Method::GET);
    tracing::debug!(
        feed_id = %feed_id,
        method = %method,
        url = %req.url,
        "sending HTTP request"
    );
    let mut builder = client.request(method, &req.url);

    if !req.params.is_empty() {
        builder = builder.query(&req.params);
    }

    for (key, value) in &req.headers {
        builder = builder.header(key.as_str(), value.as_str());
    }

    if let Some(body) = &req.body {
        builder = builder.body(body.0.clone());
    }

    let response = match builder.send().await {
        Ok(response) => response,
        Err(e) => {
            if let Some(trace) = &trace {
                trace.record_send_error(req, start, &e);
            }
            return Err(e.into());
        }
    };

    let status = response.status().as_u16();
    let url = response.url().to_string();
    tracing::debug!(
        feed_id = %feed_id,
        status,
        url = %url,
        "received HTTP response"
    );

    let headers: Vec<(String, String)> = response
        .headers()
        .iter()
        .filter_map(|(k, v)| {
            v.to_str()
                .ok()
                .map(|val| (k.as_str().to_owned(), val.to_owned()))
        })
        .collect();

    let body = match response.bytes().await {
        Ok(body) => body,
        Err(e) => {
            if let Some(trace) = &trace {
                trace.record_body_error(req, status, &url, start, &e);
            }
            return Err(e.into());
        }
    };

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

// ---------------------------------------------------------------------------
// Domain allowlist helper
// ---------------------------------------------------------------------------

/// Check whether the host of `url` is permitted by `access_domains`.
///
/// Each entry in `access_domains` must be an exact hostname.
/// Returns `true` if the host is allowed, `false` if the URL cannot be parsed
/// or the host is not in the list.
fn domain_allowed(url: &str, access_domains: &HashSet<String>) -> bool {
    let parsed = match reqwest::Url::parse(url) {
        Ok(u) => u,
        Err(_) => return false,
    };
    let host = match parsed.host_str() {
        Some(h) => h,
        None => return false,
    };
    access_domains.contains(host)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::{HttpBody, shared_client};

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
    fn http_body_from_str_works() {
        let body: HttpBody = "abc".parse().expect("infallible parse should succeed");
        assert_eq!(body.as_str().expect("valid utf-8"), "abc");
    }

    #[test]
    fn shared_client_returns_one_instance() {
        // The shared client must hand out the same instance on every call so
        // all cookie-free callers reuse one connection pool.
        assert!(std::ptr::eq(shared_client(), shared_client()));
    }
}

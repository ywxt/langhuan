use std::collections::{HashMap, HashSet};
use std::sync::RwLock;
use std::time::Duration;

use async_stream::stream;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::Mutex as AsyncMutex;
use tokio::time::sleep;
use tokio_stream::StreamExt as _;

use super::sandbox::{JsObject, Sandbox};

use crate::error::{ExpectedErrorCode, Result};
use crate::feed::{
    AuthEntry, AuthInfo, AuthPageContext, AuthStatus, Feed, FeedAuthFlow, FeedMeta, FeedStream,
};
use crate::http::{self, HttpRequest, HttpResponse};
use crate::model::{BookInfo, ChapterInfo, Page, Paragraph, RawParagraph, SearchResult};

const SCRIPT_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_INTERNAL_REQUESTS: usize = 8;
const MAX_RETRIES: u32 = 3;
const BASE_DELAY_MS: u64 = 200;
const BACKOFF_MULTIPLIER: u64 = 3;
const MAX_CACHED_RESPONSES: usize = 8;
const MAX_CACHED_RESPONSE_BYTES: usize = 1024 * 1024;

type JsMethodPath = &'static [&'static str];

const SEARCH_HANDLER: JsMethodPath = &["search"];
const BOOK_INFO_HANDLER: JsMethodPath = &["bookInfo"];
const CHAPTERS_HANDLER: JsMethodPath = &["chapters"];
const PARAGRAPHS_HANDLER: JsMethodPath = &["paragraphs"];
const LOGIN_ENTRY_HANDLER: JsMethodPath = &["login", "entry"];
const LOGIN_PARSE_HANDLER: JsMethodPath = &["login", "parse"];
const LOGIN_PATCH_REQUEST_HANDLER: JsMethodPath = &["login", "patchRequest"];
const LOGIN_STATUS_HANDLER: JsMethodPath = &["login", "status"];

const REQUIRED_HANDLERS: &[JsMethodPath] = &[
    SEARCH_HANDLER,
    BOOK_INFO_HANDLER,
    CHAPTERS_HANDLER,
    PARAGRAPHS_HANDLER,
];
const REQUIRED_LOGIN_HANDLERS: &[JsMethodPath] = &[
    LOGIN_ENTRY_HANDLER,
    LOGIN_PARSE_HANDLER,
    LOGIN_PATCH_REQUEST_HANDLER,
];

const PRELUDE: &str = r#"
globalThis.FeedError = Object.freeze({
  authRequired(message) {
    return { type: "fail", code: "auth_required", message: String(message) };
  },
  cfChallenge(message) {
    return { type: "fail", code: "cf_challenge", message: String(message) };
  },
  rateLimited(message) {
    return { type: "fail", code: "rate_limited", message: String(message) };
  },
  contentNotFound(message) {
    return { type: "fail", code: "content_not_found", message: String(message) };
  },
  sourceUnavailable(message) {
    return { type: "fail", code: "source_unavailable", message: String(message) };
  },
  raise(code, message) {
    return { type: "fail", code: String(code), message: String(message) };
  },
});

// QuickJS intentionally has no browser APIs. These pure helpers are enough
// for site-provided decryptors without granting network or system access.
globalThis.atob = function(input) {
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=";
  let str = String(input).replace(/=+$/, "");
  let output = "";
  if (str.length % 4 === 1) throw new TypeError("invalid base64");
  for (let bc = 0, bs, buffer, idx = 0;
       (buffer = str.charAt(idx++));
       ~buffer && (bs = bc % 4 ? bs * 64 + buffer : buffer,
       bc++ % 4) ? output += String.fromCharCode(255 & bs >> (-2 * bc & 6)) : 0) {
    buffer = chars.indexOf(buffer);
  }
  return output;
};
globalThis.window = globalThis;
globalThis.self = globalThis;
globalThis.navigator = { userAgent: "Langhuan QuickJS" };
globalThis.console = {
  log() {}, info() {}, warn() {}, error() {}, debug() {}, trace() {}
};
globalThis.performance = { now() { return Date.now(); } };
globalThis.setTimeout = function(callback) {
  if (typeof callback === "function") callback();
  return 0;
};
globalThis.clearTimeout = function() {};
globalThis.setInterval = function() { return 0; };
globalThis.clearInterval = function() {};
"#;

#[derive(Clone)]
pub struct JsSupportAuth;

#[derive(Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
enum JsOperationKind {
    Search,
    BookInfo,
    Chapters,
    Paragraphs,
    AuthStatus,
}

impl JsOperationKind {
    const fn handler(self) -> JsMethodPath {
        match self {
            Self::Search => SEARCH_HANDLER,
            Self::BookInfo => BOOK_INFO_HANDLER,
            Self::Chapters => CHAPTERS_HANDLER,
            Self::Paragraphs => PARAGRAPHS_HANDLER,
            Self::AuthStatus => LOGIN_STATUS_HANDLER,
        }
    }
}

#[derive(Serialize)]
struct JsOperation {
    #[serde(rename = "operation")]
    kind: JsOperationKind,
    input: Value,
}

impl JsOperation {
    fn new(kind: JsOperationKind, input: Value) -> Self {
        Self { kind, input }
    }
}

/// A JavaScript-backed feed. Scripts are reducers: they can only return a
/// request descriptor, a completed value, or a structured failure. Rust owns
/// every network call and invokes the reducer again with the response.
pub struct JsFeed {
    meta: FeedMeta,
    client: reqwest::Client,
    has_login: bool,
    has_auth_status: bool,
    auth_info: RwLock<Option<AuthInfo>>,
    response_cache: AsyncMutex<HashMap<String, HttpResponse>>,
    feed_object: JsObject,
}

#[derive(Serialize)]
struct JsEvent<'a> {
    #[serde(flatten)]
    operation: &'a JsOperation,
    cursor: &'a Value,
    state: &'a Value,
    response: Option<JsResponse>,
    auth: Option<Value>,
}

#[derive(Serialize)]
struct JsResponse {
    status: u16,
    headers: Vec<(String, String)>,
    body: String,
    url: String,
}

impl From<HttpResponse> for JsResponse {
    fn from(response: HttpResponse) -> Self {
        Self {
            status: response.status,
            headers: response.headers,
            body: String::from_utf8_lossy(&response.body.0).into_owned(),
            url: response.url,
        }
    }
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum JsStep {
    Request {
        request: HttpRequest,
        #[serde(default)]
        next_state: Value,
        #[serde(default)]
        cache_key: Option<String>,
    },
    Complete {
        #[serde(default)]
        items: Option<Value>,
        #[serde(default)]
        value: Option<Value>,
        #[serde(default)]
        next_cursor: Option<Value>,
    },
    Fail {
        code: String,
        message: String,
    },
}

struct Complete {
    items: Option<Value>,
    value: Option<Value>,
    next_cursor: Option<Value>,
}

impl JsFeed {
    pub(crate) fn new(source: String, meta: FeedMeta, client: reqwest::Client) -> Result<Self> {
        let meta_json = serde_json::to_string(&meta)
            .map_err(|error| crate::error::Error::javascript(error.to_string()))?;
        let mut sandbox = Sandbox::new(SCRIPT_TIMEOUT)?;
        sandbox.eval_script(&format!(
            "{PRELUDE}\nglobalThis.meta = Object.freeze({meta_json});"
        ))?;
        let feed_object = sandbox.eval_object(&format!("({source})"))?;
        if sandbox.has_global("feed")? {
            return Err(crate::error::Error::invalid_feed(
                "JavaScript feed must return its handler object instead of assigning globalThis.feed",
            ));
        }
        if !Self::has_methods(&feed_object, REQUIRED_HANDLERS)? {
            let names = REQUIRED_HANDLERS
                .iter()
                .filter_map(|path| path.last())
                .copied()
                .collect::<Vec<_>>()
                .join(", ");
            return Err(crate::error::Error::invalid_feed(format!(
                "JavaScript feed must return an object with {names} functions"
            )));
        }

        let login_methods = Self::method_presence(&feed_object, REQUIRED_LOGIN_HANDLERS)?;
        let has_auth_status = feed_object.has_function(LOGIN_STATUS_HANDLER)?;
        let has_login = login_methods.iter().all(|present| *present);
        if (login_methods.iter().any(|present| *present) || has_auth_status) && !has_login {
            let names = REQUIRED_LOGIN_HANDLERS
                .iter()
                .map(|path| path.join("."))
                .collect::<Vec<_>>()
                .join(", ");
            return Err(crate::error::Error::invalid_feed(format!(
                "JavaScript feed login support must define all of: {names}"
            )));
        }

        Ok(Self {
            meta,
            client,
            has_login,
            has_auth_status,
            auth_info: RwLock::new(None),
            response_cache: AsyncMutex::new(HashMap::new()),
            feed_object,
        })
    }

    fn has_methods(object: &JsObject, paths: &[JsMethodPath]) -> Result<bool> {
        Ok(Self::method_presence(object, paths)?
            .into_iter()
            .all(|present| present))
    }

    fn method_presence(object: &JsObject, paths: &[JsMethodPath]) -> Result<Vec<bool>> {
        paths.iter().map(|path| object.has_function(path)).collect()
    }

    fn auth_info(&self) -> Result<Option<AuthInfo>> {
        self.auth_info
            .read()
            .map_err(|_| crate::error::Error::invalid_feed("auth state lock poisoned"))
            .map(|auth| auth.clone())
    }

    fn to_js_value(value: &impl Serialize, description: &str) -> Result<Value> {
        serde_json::to_value(value).map_err(|error| {
            crate::error::Error::javascript(format!(
                "failed to serialize {description} for JavaScript: {error}"
            ))
        })
    }

    fn call_method(&self, path: JsMethodPath, args: &[Value]) -> Result<Value> {
        self.feed_object.call_json(path, args)
    }

    fn invoke(&self, operation: &JsOperation, event: &JsEvent<'_>) -> Result<JsStep> {
        let event = Self::to_js_value(event, "feed event")?;
        let value = self.call_method(operation.kind.handler(), &[event])?;
        serde_json::from_value(value)
            .map_err(|e| crate::error::Error::javascript(format!("invalid feed step: {e}")))
    }

    async fn execute_http_with_retry(&self, request: &HttpRequest) -> Result<HttpResponse> {
        let mut attempt = 0u32;
        loop {
            match http::execute(
                &self.client,
                &self.meta.id,
                &self.meta.access_domains,
                request,
            )
            .await
            {
                Ok(response) => return Ok(response),
                Err(error) if attempt < MAX_RETRIES && error.is_retryable() => {
                    let delay = BASE_DELAY_MS * BACKOFF_MULTIPLIER.pow(attempt);
                    sleep(Duration::from_millis(delay)).await;
                    attempt += 1;
                }
                Err(error) => return Err(error),
            }
        }
    }

    async fn execute_cached_http(
        &self,
        request: &HttpRequest,
        cache_key: Option<&str>,
    ) -> Result<HttpResponse> {
        let Some(cache_key) = cache_key.filter(|key| !key.is_empty() && key.len() <= 128) else {
            return self.execute_http_with_retry(request).await;
        };

        // Hold the small per-feed cache lock across the request to provide
        // single-flight behavior when the reader preloads adjacent chapters.
        let mut cache = self.response_cache.lock().await;
        if let Some(response) = cache.get(cache_key) {
            return Ok(response.clone());
        }

        let response = self.execute_http_with_retry(request).await?;
        if response.status == 200
            && response.body.0.len() <= MAX_CACHED_RESPONSE_BYTES
            && cache.len() < MAX_CACHED_RESPONSES
        {
            cache.insert(cache_key.to_owned(), response.clone());
        }
        Ok(response)
    }

    fn apply_auth_patch(
        &self,
        operation: &JsOperation,
        request: HttpRequest,
    ) -> Result<HttpRequest> {
        if !self.has_login {
            return Ok(request);
        }
        let Some(auth) = self.auth_info()? else {
            return Ok(request);
        };
        let value = self.call_method(
            LOGIN_PATCH_REQUEST_HANDLER,
            &[
                Self::to_js_value(operation, "operation")?,
                Self::to_js_value(&request, "HTTP request")?,
                auth,
            ],
        )?;
        serde_json::from_value(value)
            .map_err(|e| crate::error::Error::javascript(format!("invalid patched request: {e}")))
    }

    async fn run_operation(&self, operation: &JsOperation, cursor: &Value) -> Result<Complete> {
        let mut state = Value::Null;
        let mut response = None;
        let mut requests = 0usize;

        loop {
            let auth = self.auth_info()?;
            let event = JsEvent {
                operation,
                cursor,
                state: &state,
                response: response.take(),
                auth,
            };
            match self.invoke(operation, &event)? {
                JsStep::Request {
                    request,
                    next_state,
                    cache_key,
                } => {
                    requests += 1;
                    if requests > MAX_INTERNAL_REQUESTS {
                        return Err(crate::error::Error::javascript(
                            "feed operation exceeded the internal request limit",
                        ));
                    }
                    let request = self.apply_auth_patch(operation, request)?;
                    let http_response = self
                        .execute_cached_http(&request, cache_key.as_deref())
                        .await?;
                    state = next_state;
                    response = Some(http_response.into());
                }
                JsStep::Complete {
                    items,
                    value,
                    next_cursor,
                } => {
                    return Ok(Complete {
                        items,
                        value,
                        next_cursor,
                    });
                }
                JsStep::Fail { code, message } => {
                    return Err(crate::error::Error::expected(
                        ExpectedErrorCode::from_code(&code),
                        message,
                    ));
                }
            }
        }
    }

    async fn run_page<T: DeserializeOwned>(
        &self,
        operation: &JsOperation,
        cursor: &Value,
    ) -> Result<Page<T, Value>> {
        let complete = self.run_operation(operation, cursor).await?;
        let items = serde_json::from_value(complete.items.unwrap_or(Value::Array(vec![])))
            .map_err(|e| crate::error::Error::javascript(format!("invalid items: {e}")))?;
        Ok(Page {
            items,
            next_cursor: complete.next_cursor.filter(|value| !value.is_null()),
        })
    }

    async fn run_value<T: DeserializeOwned>(&self, operation: &JsOperation) -> Result<T> {
        let complete = self.run_operation(operation, &Value::Null).await?;
        serde_json::from_value(complete.value.unwrap_or(Value::Null))
            .map_err(|e| crate::error::Error::javascript(format!("invalid value: {e}")))
    }

    fn paged_stream<'a, T>(&'a self, operation: JsOperation) -> FeedStream<'a, T>
    where
        T: DeserializeOwned + Send + 'a,
    {
        Box::pin(stream! {
            let mut cursor = Value::Null;
            loop {
                match self.run_page(&operation, &cursor).await {
                    Ok(page) => {
                        let next = page.next_cursor;
                        for item in page.items {
                            yield Ok(item);
                        }
                        match next {
                            Some(value) => cursor = value,
                            None => break,
                        }
                    }
                    Err(error) => {
                        yield Err(error);
                        break;
                    }
                }
            }
        })
    }

    fn dedup_stream<'a, T, F>(
        &'a self,
        inner: FeedStream<'a, T>,
        kind: &'static str,
        get_id: F,
    ) -> FeedStream<'a, T>
    where
        T: Send + 'a,
        F: Fn(&T) -> String + Send + 'a,
    {
        let feed_id = self.meta.id.clone();
        Box::pin(stream! {
            let mut seen = HashSet::new();
            let mut inner = std::pin::pin!(inner);
            while let Some(result) = inner.next().await {
                match result {
                    Ok(item) => {
                        let id = get_id(&item);
                        if !seen.insert(id.clone()) {
                            yield Err(crate::error::Error::duplicate_id(
                                feed_id.clone(), kind, id,
                            ));
                            break;
                        }
                        yield Ok(item);
                    }
                    Err(error) => {
                        yield Err(error);
                        break;
                    }
                }
            }
        })
    }
}

impl Feed for JsFeed {
    fn search<'a>(&'a self, keyword: &'a str) -> FeedStream<'a, SearchResult> {
        let operation = JsOperation::new(
            JsOperationKind::Search,
            serde_json::json!({ "keyword": keyword }),
        );
        let stream = self.paged_stream(operation);
        self.dedup_stream(stream, "book", |item: &SearchResult| item.id.clone())
    }

    async fn book_info(&self, id: &str) -> Result<BookInfo> {
        let operation = JsOperation::new(
            JsOperationKind::BookInfo,
            serde_json::json!({ "bookId": id }),
        );
        self.run_value(&operation).await
    }

    fn chapters<'a>(&'a self, book_id: &'a str) -> FeedStream<'a, ChapterInfo> {
        let operation = JsOperation::new(
            JsOperationKind::Chapters,
            serde_json::json!({ "bookId": book_id }),
        );
        let stream = self.paged_stream(operation);
        self.dedup_stream(stream, "chapter", |item: &ChapterInfo| item.id.clone())
    }

    fn paragraphs<'a>(
        &'a self,
        book_id: &'a str,
        chapter_id: &'a str,
    ) -> FeedStream<'a, Paragraph> {
        let operation = JsOperation::new(
            JsOperationKind::Paragraphs,
            serde_json::json!({
                "bookId": book_id,
                "chapterId": chapter_id,
            }),
        );
        let raw: FeedStream<'a, RawParagraph> = self.paged_stream(operation);
        let indexed: FeedStream<'a, Paragraph> = Box::pin(stream! {
            let mut index = 0usize;
            let mut raw = std::pin::pin!(raw);
            while let Some(result) = raw.next().await {
                match result {
                    Ok(item) => {
                        yield Ok(item.into_paragraph(index));
                        index += 1;
                    }
                    Err(error) => {
                        yield Err(error);
                        break;
                    }
                }
            }
        });
        self.dedup_stream(indexed, "paragraph", |item: &Paragraph| {
            item.id().to_string()
        })
    }

    fn meta(&self) -> &FeedMeta {
        &self.meta
    }
}

impl FeedAuthFlow for JsFeed {
    type SupportAuth = JsSupportAuth;

    fn supports_auth(&self) -> Option<Self::SupportAuth> {
        self.has_login.then_some(JsSupportAuth)
    }

    fn auth_entry(&self, _support: &Self::SupportAuth) -> Result<AuthEntry> {
        let value = self.call_method(LOGIN_ENTRY_HANDLER, &[])?;
        serde_json::from_value(value)
            .map_err(|e| crate::error::Error::javascript(format!("invalid auth entry: {e}")))
    }

    fn parse_auth(&self, _support: &Self::SupportAuth, page: &AuthPageContext) -> Result<AuthInfo> {
        let page = Self::to_js_value(page, "authentication page")?;
        let value = self.call_method(LOGIN_PARSE_HANDLER, &[page])?;
        if value.get("type").and_then(Value::as_str) == Some("fail") {
            return Err(crate::error::Error::expected(
                ExpectedErrorCode::from_code(
                    value.get("code").and_then(Value::as_str).unwrap_or("raise"),
                ),
                value
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("authentication failed"),
            ));
        }
        Ok(value)
    }

    fn set_auth_info(
        &self,
        _support: &Self::SupportAuth,
        auth_info: Option<AuthInfo>,
    ) -> Result<()> {
        *self
            .auth_info
            .write()
            .map_err(|_| crate::error::Error::invalid_feed("auth state lock poisoned"))? =
            auth_info;
        Ok(())
    }

    async fn auth_status(&self, _support: &Self::SupportAuth) -> Result<AuthStatus> {
        let has_auth = self.auth_info()?.is_some();
        if !has_auth {
            return Ok(AuthStatus::LoggedOut);
        }
        if !self.has_auth_status {
            return Ok(AuthStatus::LoggedIn);
        }
        let operation = JsOperation::new(
            JsOperationKind::AuthStatus,
            Value::Object(Default::default()),
        );
        let valid: bool = self.run_value(&operation).await?;
        Ok(if valid {
            AuthStatus::LoggedIn
        } else {
            AuthStatus::Expired
        })
    }
}

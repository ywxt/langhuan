use std::collections::{HashMap, HashSet};
use std::sync::{Mutex as StdMutex, RwLock};
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
    RequestPatchContext,
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
    feed_object: StdMutex<JsObject>,
}

#[derive(Serialize)]
struct JsEvent<'a> {
    input: &'a Value,
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
        let mut feed_object = sandbox.eval_object(&format!("({source})"))?;
        if sandbox.has_global("feed")? {
            return Err(crate::error::Error::invalid_feed(
                "JavaScript feed must return its handler object instead of assigning globalThis.feed",
            ));
        }
        if !["search", "bookInfo", "chapters", "paragraphs"]
            .iter()
            .map(|name| feed_object.has_function(&[*name]))
            .collect::<Result<Vec<_>>>()?
            .into_iter()
            .all(|present| present)
        {
            return Err(crate::error::Error::invalid_feed(
                "JavaScript feed must return an object with search, bookInfo, chapters and paragraphs functions",
            ));
        }

        let has_login = feed_object.has_function(&["login", "entry"])?
            && feed_object.has_function(&["login", "parse"])?
            && feed_object.has_function(&["login", "patchRequest"])?;
        let has_auth_status = feed_object.has_function(&["login", "status"])?;

        Ok(Self {
            meta,
            client,
            has_login,
            has_auth_status,
            auth_info: RwLock::new(None),
            response_cache: AsyncMutex::new(HashMap::new()),
            feed_object: StdMutex::new(feed_object),
        })
    }

    fn call_method(&self, path: &[&str], args: &[Value]) -> Result<Value> {
        let mut feed_object = self
            .feed_object
            .lock()
            .map_err(|_| crate::error::Error::javascript("QuickJS sandbox lock poisoned"))?;
        feed_object.call_json(path, args)
    }

    fn invoke(&self, handler: &[&str], event: &JsEvent<'_>) -> Result<JsStep> {
        let event = serde_json::to_value(event)
            .map_err(|e| crate::error::Error::javascript(e.to_string()))?;
        let value = self.call_method(handler, &[event])?;
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
        context: &RequestPatchContext,
        request: HttpRequest,
    ) -> Result<HttpRequest> {
        if !self.has_login {
            return Ok(request);
        }
        let auth = self
            .auth_info
            .read()
            .map_err(|_| crate::error::Error::invalid_feed("auth state lock poisoned"))?
            .clone();
        let Some(auth) = auth else {
            return Ok(request);
        };
        let value = self.call_method(
            &["login", "patchRequest"],
            &[
                serde_json::to_value(context).unwrap_or(Value::Null),
                serde_json::to_value(request).unwrap_or(Value::Null),
                auth,
            ],
        )?;
        serde_json::from_value(value)
            .map_err(|e| crate::error::Error::javascript(format!("invalid patched request: {e}")))
    }

    async fn run_operation(
        &self,
        handler: &[&str],
        input: &Value,
        cursor: &Value,
        patch_context: &RequestPatchContext,
    ) -> Result<Complete> {
        let mut state = Value::Null;
        let mut response = None;
        let mut requests = 0usize;

        loop {
            let auth = self
                .auth_info
                .read()
                .map_err(|_| crate::error::Error::invalid_feed("auth state lock poisoned"))?
                .clone();
            let event = JsEvent {
                input,
                cursor,
                state: &state,
                response: response.take(),
                auth,
            };
            match self.invoke(handler, &event)? {
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
                    let request = self.apply_auth_patch(patch_context, request)?;
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
        handler: &[&str],
        input: &Value,
        cursor: &Value,
        patch_context: &RequestPatchContext,
    ) -> Result<Page<T, Value>> {
        let complete = self
            .run_operation(handler, input, cursor, patch_context)
            .await?;
        let items = serde_json::from_value(complete.items.unwrap_or(Value::Array(vec![])))
            .map_err(|e| crate::error::Error::javascript(format!("invalid items: {e}")))?;
        Ok(Page {
            items,
            next_cursor: complete.next_cursor.filter(|value| !value.is_null()),
        })
    }

    async fn run_value<T: DeserializeOwned>(
        &self,
        handler: &[&str],
        input: &Value,
        patch_context: &RequestPatchContext,
    ) -> Result<T> {
        let complete = self
            .run_operation(handler, input, &Value::Null, patch_context)
            .await?;
        serde_json::from_value(complete.value.unwrap_or(Value::Null))
            .map_err(|e| crate::error::Error::javascript(format!("invalid value: {e}")))
    }

    fn paged_stream<'a, T>(
        &'a self,
        handler: &'static [&'static str],
        input: Value,
        patch_context: RequestPatchContext,
    ) -> FeedStream<'a, T>
    where
        T: DeserializeOwned + Send + 'a,
    {
        Box::pin(stream! {
            let mut cursor = Value::Null;
            loop {
                match self.run_page(handler, &input, &cursor, &patch_context).await {
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
        let input = serde_json::json!({ "keyword": keyword });
        let context = RequestPatchContext::Search {
            feed_id: self.meta.id.clone(),
        };
        let stream = self.paged_stream(&["search"], input, context);
        self.dedup_stream(stream, "book", |item: &SearchResult| item.id.clone())
    }

    async fn book_info(&self, id: &str) -> Result<BookInfo> {
        let input = serde_json::json!({ "bookId": id });
        let context = RequestPatchContext::BookInfo {
            feed_id: self.meta.id.clone(),
            book_id: id.to_owned(),
        };
        self.run_value(&["bookInfo"], &input, &context).await
    }

    fn chapters<'a>(&'a self, book_id: &'a str) -> FeedStream<'a, ChapterInfo> {
        let input = serde_json::json!({ "bookId": book_id });
        let context = RequestPatchContext::Chapters {
            feed_id: self.meta.id.clone(),
            book_id: book_id.to_owned(),
        };
        let stream = self.paged_stream(&["chapters"], input, context);
        self.dedup_stream(stream, "chapter", |item: &ChapterInfo| item.id.clone())
    }

    fn paragraphs<'a>(
        &'a self,
        book_id: &'a str,
        chapter_id: &'a str,
    ) -> FeedStream<'a, Paragraph> {
        let input = serde_json::json!({
            "bookId": book_id,
            "chapterId": chapter_id,
        });
        let context = RequestPatchContext::Paragraphs {
            feed_id: self.meta.id.clone(),
            book_id: book_id.to_owned(),
            chapter_id: chapter_id.to_owned(),
        };
        let raw: FeedStream<'a, RawParagraph> = self.paged_stream(&["paragraphs"], input, context);
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
        let value = self.call_method(&["login", "entry"], &[])?;
        serde_json::from_value(value)
            .map_err(|e| crate::error::Error::javascript(format!("invalid auth entry: {e}")))
    }

    fn parse_auth(&self, _support: &Self::SupportAuth, page: &AuthPageContext) -> Result<AuthInfo> {
        let page = serde_json::to_value(page)
            .map_err(|e| crate::error::Error::javascript(e.to_string()))?;
        let value = self.call_method(&["login", "parse"], &[page])?;
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
        let has_auth = self
            .auth_info
            .read()
            .map_err(|_| crate::error::Error::invalid_feed("auth state lock poisoned"))?
            .is_some();
        if !has_auth {
            return Ok(AuthStatus::LoggedOut);
        }
        if !self.has_auth_status {
            return Ok(AuthStatus::LoggedIn);
        }
        let context = RequestPatchContext::AuthStatus {
            feed_id: self.meta.id.clone(),
        };
        let valid: bool = self
            .run_value(
                &["login", "status"],
                &Value::Object(Default::default()),
                &context,
            )
            .await?;
        Ok(if valid {
            AuthStatus::LoggedIn
        } else {
            AuthStatus::Expired
        })
    }
}

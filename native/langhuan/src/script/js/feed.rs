use std::collections::{HashMap, HashSet};
use std::sync::RwLock;
use std::time::Duration;

use async_stream::stream;
use serde::de::DeserializeOwned;
use serde::Serialize;
use serde_json::Value;
use tokio::sync::Mutex as AsyncMutex;
use tokio::time::sleep;
use tokio_stream::StreamExt as _;

use super::bridge::{
    build_auth_page, build_event, build_request_object, js_to_json, jsdata_to_js, json_to_js,
    optional_string, read_http_request, read_step, required_string, JsData, OperationSpec,
    OpaqueJsValue, Round, Step,
};
use super::sandbox::{JsObject, Sandbox};

use crate::error::{ExpectedErrorCode, Result};
use crate::feed::{
    AuthEntry, AuthInfo, AuthPageContext, AuthStatus, Feed, FeedAuthFlow, FeedMeta, FeedStream,
    SharedWebviewHandler, WebviewRequest, WebviewSnapshot,
};
use crate::http::{self, HttpRequest, HttpResponse};
use crate::model::{BookInfo, ChapterInfo, Page, Paragraph, RawParagraph, SearchResult};

const SCRIPT_TIMEOUT: Duration = Duration::from_secs(30);
const COMPUTE_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_INTERNAL_STEPS: usize = 8;
const MAX_USER_AGENT_BYTES: usize = 512;
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
globalThis.btoa = function(input) {
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  let str = String(input);
  let output = "";
  for (let idx = 0; idx < str.length; idx += 3) {
    const a = str.charCodeAt(idx);
    const b = str.charCodeAt(idx + 1);
    const c = str.charCodeAt(idx + 2);
    const hasB = idx + 1 < str.length;
    const hasC = idx + 2 < str.length;
    output += chars.charAt(a >> 2);
    output += chars.charAt(((a & 3) << 4) | (hasB ? b >> 4 : 0));
    output += hasB ? chars.charAt(((b & 15) << 2) | (hasC ? c >> 6 : 0)) : "=";
    output += hasC ? chars.charAt(c & 63) : "=";
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

    /// The snake-case operation name delivered in the reducer event.
    const fn as_str(self) -> &'static str {
        match self {
            Self::Search => "search",
            Self::BookInfo => "book_info",
            Self::Chapters => "chapters",
            Self::Paragraphs => "paragraphs",
            Self::AuthStatus => "auth_status",
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

/// A JavaScript-backed feed. Scripts are reducers: they can return a request,
/// an isolated computation, a completed value, or a structured failure. Rust
/// owns every network call and invokes the reducer again with the result.
pub struct JsFeed {
    meta: FeedMeta,
    client: reqwest::Client,
    has_login: bool,
    has_auth_status: bool,
    auth_info: RwLock<Option<AuthInfo>>,
    response_cache: AsyncMutex<HashMap<String, HttpResponse>>,
    webview_handler: RwLock<Option<SharedWebviewHandler>>,
    feed_object: JsObject,
}

struct Complete {
    items: Option<Value>,
    value: Option<Value>,
    next_cursor: Option<Value>,
}

impl JsFeed {
    fn validate_user_agent(user_agent: &str) -> Result<()> {
        if user_agent.is_empty() {
            return Err(crate::error::Error::javascript(
                "user_agent must not be empty",
            ));
        }
        if user_agent.len() > MAX_USER_AGENT_BYTES {
            return Err(crate::error::Error::javascript(format!(
                "user_agent exceeds {MAX_USER_AGENT_BYTES} bytes"
            )));
        }
        if user_agent.chars().any(char::is_control) {
            return Err(crate::error::Error::javascript(
                "user_agent must not contain control characters",
            ));
        }
        Ok(())
    }

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
            webview_handler: RwLock::new(None),
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

    /// Install or remove the host-side WebView provider. Without one, any
    /// `webview` step a script returns fails with an auth-required error.
    pub fn set_webview_handler(&self, handler: Option<SharedWebviewHandler>) -> Result<()> {
        *self
            .webview_handler
            .write()
            .map_err(|_| crate::error::Error::invalid_feed("webview handler lock poisoned"))? =
            handler;
        Ok(())
    }

    fn webview_handler(&self) -> Result<Option<SharedWebviewHandler>> {
        self.webview_handler
            .read()
            .map_err(|_| crate::error::Error::invalid_feed("webview handler lock poisoned"))
            .map(|handler| handler.clone())
    }

    fn to_js_value(value: &impl Serialize, description: &str) -> Result<Value> {
        serde_json::to_value(value).map_err(|error| {
            crate::error::Error::javascript(format!(
                "failed to serialize {description} for JavaScript: {error}"
            ))
        })
    }

    /// Invoke the operation's reducer once with a live event object.
    fn invoke(&self, operation: &JsOperation, round: Round<'_>) -> Result<Step> {
        let spec = OperationSpec {
            kind: operation.kind.as_str(),
            input: &operation.input,
        };
        let handler = operation.kind.handler();
        self.feed_object.with_realm(move |ctx, feed_object| {
            let event = build_event(&ctx, &spec, &round)?;
            let (owner, function) = super::bridge::resolve_method(&feed_object, handler)?;
            let result = super::bridge::call_method(&ctx, &owner, &function, &[event])?;
            Ok(read_step(&ctx, &result))
        })
    }

    /// Materialize a compute result into the feed realm as an opaque value.
    fn restore_compute(&self, data: JsData) -> Result<OpaqueJsValue> {
        self.feed_object.with_realm(move |ctx, _| {
            let value = jsdata_to_js(&ctx, &data)?;
            Ok(Ok(OpaqueJsValue::save(&ctx, value)))
        })
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
        let operation_json = Self::to_js_value(operation, "operation")?;
        self.feed_object.with_realm(move |ctx, feed_object| {
            let operation_arg = json_to_js(&ctx, &operation_json)?;
            let request_arg = build_request_object(&ctx, &request)?;
            let auth_arg = json_to_js(&ctx, &auth)?;
            let (owner, function) =
                super::bridge::resolve_method(&feed_object, LOGIN_PATCH_REQUEST_HANDLER)?;
            let result = super::bridge::call_method(
                &ctx,
                &owner,
                &function,
                &[operation_arg, request_arg, auth_arg],
            )?;
            Ok((|| {
                let object = result.into_object().ok_or_else(|| {
                    crate::error::Error::javascript(
                        "invalid patched request: expected an object",
                    )
                })?;
                read_http_request(&object, "invalid patched request")
            })())
        })
    }

    async fn run_operation(&self, operation: &JsOperation, cursor: &Value) -> Result<Complete> {
        // `state` and `compute` are opaque JavaScript values passed between
        // rounds untouched; `response` and `webview` are fresh host data.
        let mut state: Option<OpaqueJsValue> = None;
        let mut compute: Option<OpaqueJsValue> = None;
        let mut response: Option<HttpResponse> = None;
        let mut webview: Option<WebviewSnapshot> = None;
        let mut internal_steps = 0usize;

        loop {
            let auth = self.auth_info()?;
            let round = Round {
                cursor,
                state: state.take(),
                compute: compute.take(),
                response: response.as_ref(),
                auth: auth.as_ref(),
                webview: webview.as_ref(),
            };
            let step = self.invoke(operation, round)?;
            // `response` and `webview` are one-shot: the reducer saw them this
            // round, so the next round must not deliver them again.
            response = None;
            webview = None;
            match step {
                Step::Request {
                    request,
                    next_state,
                    cache_key,
                } => {
                    internal_steps += 1;
                    if internal_steps > MAX_INTERNAL_STEPS {
                        return Err(crate::error::Error::javascript(
                            "feed operation exceeded the internal step limit",
                        ));
                    }
                    let request = self.apply_auth_patch(operation, request)?;
                    let http_response = self
                        .execute_cached_http(&request, cache_key.as_deref())
                        .await?;
                    state = next_state;
                    response = Some(http_response);
                }
                Step::Compute {
                    programs,
                    input,
                    next_state,
                } => {
                    internal_steps += 1;
                    if internal_steps > MAX_INTERNAL_STEPS {
                        return Err(crate::error::Error::javascript(
                            "feed operation exceeded the internal step limit",
                        ));
                    }
                    let result = tokio::task::spawn_blocking(move || {
                        Sandbox::compute(&programs, &input, COMPUTE_TIMEOUT)
                    })
                    .await
                    .map_err(|error| {
                        crate::error::Error::javascript(format!("compute worker failed: {error}"))
                    })??;
                    compute = Some(self.restore_compute(result)?);
                    state = next_state;
                }
                Step::Webview {
                    url,
                    title,
                    user_agent,
                    next_state,
                } => {
                    Self::validate_user_agent(&user_agent)?;
                    internal_steps += 1;
                    if internal_steps > MAX_INTERNAL_STEPS {
                        return Err(crate::error::Error::javascript(
                            "feed operation exceeded the internal step limit",
                        ));
                    }
                    let handler = self.webview_handler()?.ok_or_else(|| {
                        crate::error::Error::expected(
                            ExpectedErrorCode::AuthRequired,
                            "WebView verification is unavailable in this environment",
                        )
                    })?;
                    let request = WebviewRequest {
                        feed_id: self.meta.id.clone(),
                        feed_name: self.meta.name.clone(),
                        url,
                        title,
                        user_agent,
                    };
                    let snapshot = handler.open(request).await?;
                    state = next_state;
                    webview = Some(snapshot);
                }
                Step::Complete {
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
                Step::Fail { code, message } => {
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
        let entry = self.feed_object.with_realm(|ctx, feed_object| {
            let (owner, function) =
                super::bridge::resolve_method(&feed_object, LOGIN_ENTRY_HANDLER)?;
            let result = super::bridge::call_method(&ctx, &owner, &function, &[])?;
            Ok((|| {
                let object = result.into_object().ok_or_else(|| {
                    crate::error::Error::javascript("invalid auth entry: expected an object")
                })?;
                Ok(AuthEntry {
                    url: required_string(&object, "url", "invalid auth entry")?,
                    title: optional_string(&object, "title", "invalid auth entry")?,
                    user_agent: required_string(
                        &object,
                        "user_agent",
                        "invalid auth entry",
                    )?,
                })
            })())
        })?;
        Self::validate_user_agent(&entry.user_agent)?;
        Ok(entry)
    }

    fn parse_auth(&self, _support: &Self::SupportAuth, page: &AuthPageContext) -> Result<AuthInfo> {
        self.feed_object.with_realm(move |ctx, feed_object| {
            let page_arg = build_auth_page(&ctx, page)?;
            let (owner, function) =
                super::bridge::resolve_method(&feed_object, LOGIN_PARSE_HANDLER)?;
            let result = super::bridge::call_method(&ctx, &owner, &function, &[page_arg])?;
            Ok((|| {
                if let Some(object) = result.clone().into_object()
                    && let Ok(step_type) = object.get::<_, String>("type")
                    && step_type == "fail"
                {
                    let code = object
                        .get::<_, String>("code")
                        .unwrap_or_else(|_| "raise".to_owned());
                    let message = object
                        .get::<_, String>("message")
                        .unwrap_or_else(|_| "authentication failed".to_owned());
                    return Err(crate::error::Error::expected(
                        ExpectedErrorCode::from_code(&code),
                        message,
                    ));
                }
                match js_to_json(&ctx, &result).map_err(|error| {
                    crate::error::Error::javascript(format!(
                        "invalid authentication result: {error}"
                    ))
                })? {
                    Some(value) => Ok(value),
                    None => Err(crate::error::Error::javascript(
                        "invalid authentication result: method returned undefined",
                    )),
                }
            })())
        })
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

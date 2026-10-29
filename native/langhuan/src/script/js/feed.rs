use std::collections::{HashMap, HashSet};
use std::sync::RwLock;
use std::time::Duration;

use async_stream::stream;
use rquickjs::IntoJs;
use serde::de::DeserializeOwned;
use serde_json::Value;
use tokio::sync::Mutex as AsyncMutex;
use tokio::time::sleep;
use tokio_stream::StreamExt as _;

use super::bridge::{
    JsData, OpaqueJsValue, OperationSpec, Round, Step, StepOutcome, build_event, call_handler,
    read_auth_entry, read_auth_result, read_patched_request, read_step, restore_compute,
};
use super::prelude::PRELUDE;
use super::sandbox::{JsObject, Sandbox};

use crate::error::{Error, ExpectedErrorCode, Result};
use crate::feed::{
    AuthEntry, AuthInfo, AuthPageContext, AuthStatus, Feed, FeedAuthFlow, FeedMeta, FeedStream,
    SharedWebviewHandler, WebviewRequest,
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

#[derive(Clone)]
pub struct JsSupportAuth;

/// One operation of the feed contract, carrying the typed arguments its
/// reducer receives as `event.input`.
enum JsOperation<'a> {
    Search {
        keyword: &'a str,
    },
    BookInfo {
        book_id: &'a str,
    },
    Chapters {
        book_id: &'a str,
    },
    Paragraphs {
        book_id: &'a str,
        chapter_id: &'a str,
    },
    AuthStatus,
}

impl JsOperation<'_> {
    /// The handler path on the feed object.
    fn handler(&self) -> JsMethodPath {
        match self {
            Self::Search { .. } => SEARCH_HANDLER,
            Self::BookInfo { .. } => BOOK_INFO_HANDLER,
            Self::Chapters { .. } => CHAPTERS_HANDLER,
            Self::Paragraphs { .. } => PARAGRAPHS_HANDLER,
            Self::AuthStatus => LOGIN_STATUS_HANDLER,
        }
    }

    /// The snake-case operation name delivered in the reducer event.
    fn kind(&self) -> &'static str {
        match self {
            Self::Search { .. } => "search",
            Self::BookInfo { .. } => "book_info",
            Self::Chapters { .. } => "chapters",
            Self::Paragraphs { .. } => "paragraphs",
            Self::AuthStatus => "auth_status",
        }
    }

    /// The `event.input` object, built from the typed arguments.
    fn input(&self) -> JsData {
        match self {
            Self::Search { keyword } => JsData::obj([("keyword", JsData::str(*keyword))]),
            Self::BookInfo { book_id } => JsData::obj([("bookId", JsData::str(*book_id))]),
            Self::Chapters { book_id } => JsData::obj([("bookId", JsData::str(*book_id))]),
            Self::Paragraphs {
                book_id,
                chapter_id,
            } => JsData::obj([
                ("bookId", JsData::str(*book_id)),
                ("chapterId", JsData::str(*chapter_id)),
            ]),
            Self::AuthStatus => JsData::obj([]),
        }
    }

    /// The `{operation, input}` object `login.patchRequest` receives.
    fn patch_argument(&self) -> JsData {
        JsData::obj([
            ("operation", JsData::str(self.kind())),
            ("input", self.input()),
        ])
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

/// The final outcome of an operation, separated from [`Step`] so the
/// per-round union does not leak into callers.
struct Complete {
    items: Option<Value>,
    value: Option<Value>,
    next_cursor: Option<JsData>,
}

impl JsFeed {
    pub(crate) fn new(source: String, meta: FeedMeta, client: reqwest::Client) -> Result<Self> {
        let meta_json =
            serde_json::to_string(&meta).map_err(|error| Error::javascript(error.to_string()))?;
        let mut sandbox = Sandbox::new(SCRIPT_TIMEOUT)?;
        sandbox.eval_script(&format!(
            "{PRELUDE}\nglobalThis.meta = Object.freeze({meta_json});"
        ))?;
        let feed_object = sandbox.eval_object(&format!("({source})"))?;
        if sandbox.has_global("feed")? {
            return Err(Error::invalid_feed(
                "JavaScript feed must return its handler object instead of assigning globalThis.feed",
            ));
        }
        Self::require_handlers(&feed_object)?;
        let (has_login, has_auth_status) = Self::login_capabilities(&feed_object)?;

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

    /// Every feed must define the four content handlers.
    fn require_handlers(feed_object: &JsObject) -> Result<()> {
        if !feed_object.has_functions(REQUIRED_HANDLERS)? {
            let names = REQUIRED_HANDLERS
                .iter()
                .filter_map(|path| path.last())
                .copied()
                .collect::<Vec<_>>()
                .join(", ");
            return Err(Error::invalid_feed(format!(
                "JavaScript feed must return an object with {names} functions"
            )));
        }
        Ok(())
    }

    /// Login support is all-or-nothing: `entry`, `parse`, and `patchRequest`
    /// must all exist if any login-related handler does.
    fn login_capabilities(feed_object: &JsObject) -> Result<(bool, bool)> {
        let has_auth_status = feed_object.has_function(LOGIN_STATUS_HANDLER)?;
        let presence = REQUIRED_LOGIN_HANDLERS
            .iter()
            .map(|path| feed_object.has_function(path))
            .collect::<Result<Vec<_>>>()?;
        let has_login = presence.iter().all(|present| *present);
        if (presence.iter().any(|present| *present) || has_auth_status) && !has_login {
            let names = REQUIRED_LOGIN_HANDLERS
                .iter()
                .map(|path| path.join("."))
                .collect::<Vec<_>>()
                .join(", ");
            return Err(Error::invalid_feed(format!(
                "JavaScript feed login support must define all of: {names}"
            )));
        }
        Ok((has_login, has_auth_status))
    }

    fn validate_user_agent(user_agent: &str) -> Result<()> {
        if user_agent.is_empty() {
            return Err(Error::javascript("user_agent must not be empty"));
        }
        if user_agent.len() > MAX_USER_AGENT_BYTES {
            return Err(Error::javascript(format!(
                "user_agent exceeds {MAX_USER_AGENT_BYTES} bytes"
            )));
        }
        if user_agent.chars().any(char::is_control) {
            return Err(Error::javascript(
                "user_agent must not contain control characters",
            ));
        }
        Ok(())
    }

    fn auth_info(&self) -> Result<Option<AuthInfo>> {
        self.auth_info
            .read()
            .map_err(|_| Error::invalid_feed("auth state lock poisoned"))
            .map(|auth| auth.clone())
    }

    /// Install or remove the host-side WebView provider. Without one, any
    /// `webview` step a script returns fails with an auth-required error.
    pub fn set_webview_handler(&self, handler: Option<SharedWebviewHandler>) -> Result<()> {
        *self
            .webview_handler
            .write()
            .map_err(|_| Error::invalid_feed("webview handler lock poisoned"))? = handler;
        Ok(())
    }

    fn webview_handler(&self) -> Result<Option<SharedWebviewHandler>> {
        self.webview_handler
            .read()
            .map_err(|_| Error::invalid_feed("webview handler lock poisoned"))
            .map(|handler| handler.clone())
    }

    /// Invoke the operation's reducer once with a live event object.
    fn invoke(&self, operation: &JsOperation<'_>, round: Round<'_>) -> Result<Step> {
        let input = operation.input();
        let spec = OperationSpec {
            kind: operation.kind(),
            input: &input,
        };
        let handler = operation.handler();
        self.feed_object.with_realm(move |ctx, feed_object| {
            let event = build_event(&ctx, &spec, &round)?;
            let result = call_handler(&ctx, &feed_object, handler, &[event])?;
            Ok(read_step(&ctx, &result))
        })
    }

    /// Run `login.patchRequest` over a request when the feed is logged in.
    fn apply_auth_patch(
        &self,
        operation: &JsOperation<'_>,
        request: HttpRequest,
    ) -> Result<HttpRequest> {
        if !self.has_login {
            return Ok(request);
        }
        let Some(auth) = self.auth_info()? else {
            return Ok(request);
        };
        let operation_argument = operation.patch_argument();
        self.feed_object.with_realm(move |ctx, feed_object| {
            let operation_arg = operation_argument.into_js(&ctx)?;
            let request_arg = (&request).into_js(&ctx)?;
            let auth_arg = JsData::from_json(&auth).into_js(&ctx)?;
            let result = call_handler(
                &ctx,
                &feed_object,
                LOGIN_PATCH_REQUEST_HANDLER,
                &[operation_arg, request_arg, auth_arg],
            )?;
            Ok(read_patched_request(&result))
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

    async fn run_operation(
        &self,
        operation: &JsOperation<'_>,
        cursor: &JsData,
    ) -> Result<Complete> {
        // `state` threads opaque JavaScript values between rounds; the
        // executed step's result is carried as `outcome` and consumed by the
        // next round.
        let mut state: Option<OpaqueJsValue> = None;
        let mut outcome: Option<StepOutcome> = None;
        let mut steps_left = MAX_INTERNAL_STEPS;

        loop {
            let auth = self.auth_info()?;
            let round = Round {
                cursor,
                state: state.take(),
                outcome: outcome.take(),
                auth: auth.as_ref(),
            };
            let step = self.invoke(operation, round)?;
            match step {
                Step::Request {
                    request,
                    next_state,
                    cache_key,
                } => {
                    spend_step(&mut steps_left)?;
                    let request = self.apply_auth_patch(operation, request)?;
                    let http_response = self
                        .execute_cached_http(&request, cache_key.as_deref())
                        .await?;
                    state = next_state;
                    outcome = Some(StepOutcome::Response(http_response));
                }
                Step::Compute {
                    programs,
                    input,
                    next_state,
                } => {
                    spend_step(&mut steps_left)?;
                    let result = tokio::task::spawn_blocking(move || {
                        Sandbox::compute(&programs, &input, COMPUTE_TIMEOUT)
                    })
                    .await
                    .map_err(|error| {
                        Error::javascript(format!("compute worker failed: {error}"))
                    })??;
                    let restored = restore_compute(&self.feed_object, &result)?;
                    outcome = Some(StepOutcome::Compute(restored));
                    state = next_state;
                }
                Step::Webview {
                    url,
                    title,
                    user_agent,
                    next_state,
                } => {
                    Self::validate_user_agent(&user_agent)?;
                    spend_step(&mut steps_left)?;
                    let handler = self.webview_handler()?.ok_or_else(|| {
                        Error::expected(
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
                    outcome = Some(StepOutcome::Webview(snapshot));
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
                    return Err(Error::expected(
                        ExpectedErrorCode::from_code(&code),
                        message,
                    ));
                }
            }
        }
    }

    async fn run_page<T: DeserializeOwned>(
        &self,
        operation: &JsOperation<'_>,
        cursor: &JsData,
    ) -> Result<Page<T, JsData>> {
        let complete = self.run_operation(operation, cursor).await?;
        let items = serde_json::from_value(complete.items.unwrap_or(Value::Array(Vec::new())))
            .map_err(|error| Error::javascript(format!("invalid items: {error}")))?;
        Ok(Page {
            items,
            next_cursor: complete.next_cursor,
        })
    }

    async fn run_value<T: DeserializeOwned>(&self, operation: &JsOperation<'_>) -> Result<T> {
        let complete = self.run_operation(operation, &JsData::Null).await?;
        serde_json::from_value(complete.value.unwrap_or(Value::Null))
            .map_err(|error| Error::javascript(format!("invalid value: {error}")))
    }

    fn paged_stream<'a, T>(&'a self, operation: JsOperation<'a>) -> FeedStream<'a, T>
    where
        T: DeserializeOwned + Send + 'a,
    {
        Box::pin(stream! {
            let mut cursor = JsData::Null;
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
                            yield Err(Error::duplicate_id(
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

/// Count one internal step, failing once the loop budget is spent.
fn spend_step(steps_left: &mut usize) -> Result<()> {
    *steps_left = steps_left
        .checked_sub(1)
        .ok_or_else(|| Error::javascript("feed operation exceeded the internal step limit"))?;
    Ok(())
}

impl Feed for JsFeed {
    fn search<'a>(&'a self, keyword: &'a str) -> FeedStream<'a, SearchResult> {
        let operation = JsOperation::Search { keyword };
        let stream = self.paged_stream(operation);
        self.dedup_stream(stream, "book", |item: &SearchResult| item.id.clone())
    }

    async fn book_info(&self, id: &str) -> Result<BookInfo> {
        let operation = JsOperation::BookInfo { book_id: id };
        self.run_value(&operation).await
    }

    fn chapters<'a>(&'a self, book_id: &'a str) -> FeedStream<'a, ChapterInfo> {
        let operation = JsOperation::Chapters { book_id };
        let stream = self.paged_stream(operation);
        self.dedup_stream(stream, "chapter", |item: &ChapterInfo| item.id.clone())
    }

    fn paragraphs<'a>(
        &'a self,
        book_id: &'a str,
        chapter_id: &'a str,
    ) -> FeedStream<'a, Paragraph> {
        let operation = JsOperation::Paragraphs {
            book_id,
            chapter_id,
        };
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
            let result = call_handler(&ctx, &feed_object, LOGIN_ENTRY_HANDLER, &[])?;
            Ok(read_auth_entry(&result))
        })?;
        Self::validate_user_agent(&entry.user_agent)?;
        Ok(entry)
    }

    fn parse_auth(&self, _support: &Self::SupportAuth, page: &AuthPageContext) -> Result<AuthInfo> {
        self.feed_object.with_realm(move |ctx, feed_object| {
            let page_arg = page.into_js(&ctx)?;
            let result = call_handler(&ctx, &feed_object, LOGIN_PARSE_HANDLER, &[page_arg])?;
            Ok(read_auth_result(&ctx, &result))
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
            .map_err(|_| Error::invalid_feed("auth state lock poisoned"))? = auth_info;
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
        let operation = JsOperation::AuthStatus;
        let valid: bool = self.run_value(&operation).await?;
        Ok(if valid {
            AuthStatus::LoggedIn
        } else {
            AuthStatus::Expired
        })
    }
}

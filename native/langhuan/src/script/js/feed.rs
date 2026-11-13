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
    SharedStorageHandler, SharedWebviewHandler, WebviewRequest,
};
use crate::http::{FeedClient, HttpRequest, HttpResponse, domain_allowed};
use crate::model::{BookInfo, ChapterInfo, Page, Paragraph, RawParagraph, SearchResult};

const SCRIPT_TIMEOUT: Duration = Duration::from_secs(30);
const COMPUTE_TIMEOUT: Duration = Duration::from_secs(5);
/// Total budget for one HTTP attempt (connect + send + body read). Feed
/// bodies are KB-scale chapter payloads, so half a minute is generous even
/// on slow links.
const HTTP_TIMEOUT: Duration = Duration::from_secs(30);
/// Internal steps (request/compute/webview) one operation may spend before
/// completing. Sized for the deepest legitimate source flow — fanqie's
/// device re-registration (4) plus key refreshes (4) plus the trailing
/// comment-counts request — with headroom; anything longer is a runaway
/// reducer loop the host must cut off.
const MAX_INTERNAL_STEPS: usize = 16;
/// Pages one automatically pipelined operation may fetch before the host
/// cuts it off. A handler can cycle cursors (A→B→A) so every page passes
/// the per-page advance check while the stream never completes; this
/// budget is the backstop. Sized far above the deepest legitimate
/// pagination — a ten-thousand-chapter list at a hundred items per page
/// needs a hundred.
const MAX_PIPELINE_PAGES: usize = 1_000;
/// Items one pipelined page may carry, per operation. Comments and search
/// mirror website pages (tens of items each); the chapter budget fits a
/// full SSR directory in one `complete`; a single chapter's paragraphs
/// stay far below the paragraph budget. Past these lies only a runaway
/// script, so the host fails the page instead of buffering it.
const MAX_COMMENT_ITEMS_PER_PAGE: usize = 200;
const MAX_SEARCH_ITEMS_PER_PAGE: usize = 200;
const MAX_CHAPTER_ITEMS_PER_PAGE: usize = 10_000;
const MAX_PARAGRAPH_ITEMS_PER_PAGE: usize = 2_000;
/// Encoded JSON bytes a pagination cursor may occupy, shared by the
/// explicit comments API and the automatic pipeline.
const MAX_CURSOR_BYTES: usize = 4 * 1024;
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
const CHAPTER_COMMENTS_HANDLER: JsMethodPath = &["comments", "chapter"];
const PARAGRAPH_COMMENTS_HANDLER: JsMethodPath = &["comments", "paragraph"];
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
    Invoke {
        operation: OperationKind,
        input: &'a JsData,
    },
}

#[derive(Clone, Copy)]
enum OperationKind {
    ChapterComments,
    ParagraphComments,
    Search,
    BookInfo,
    Chapters,
    Paragraphs,
    AuthStatus,
}

impl OperationKind {
    fn parse(value: &str) -> Result<Self> {
        match value {
            "comments.chapter" => Ok(Self::ChapterComments),
            "comments.paragraph" => Ok(Self::ParagraphComments),
            "search" => Ok(Self::Search),
            "bookInfo" => Ok(Self::BookInfo),
            "chapters" => Ok(Self::Chapters),
            "paragraphs" => Ok(Self::Paragraphs),
            "login.status" => Ok(Self::AuthStatus),
            _ => Err(Error::invalid_feed(format!(
                "unsupported debug operation: {value}"
            ))),
        }
    }

    fn handler(self) -> JsMethodPath {
        match self {
            Self::ChapterComments => CHAPTER_COMMENTS_HANDLER,
            Self::ParagraphComments => PARAGRAPH_COMMENTS_HANDLER,
            Self::Search => SEARCH_HANDLER,
            Self::BookInfo => BOOK_INFO_HANDLER,
            Self::Chapters => CHAPTERS_HANDLER,
            Self::Paragraphs => PARAGRAPHS_HANDLER,
            Self::AuthStatus => LOGIN_STATUS_HANDLER,
        }
    }

    fn kind(self) -> &'static str {
        match self {
            Self::ChapterComments => "comments.chapter",
            Self::ParagraphComments => "comments.paragraph",
            Self::Search => "search",
            Self::BookInfo => "bookInfo",
            Self::Chapters => "chapters",
            Self::Paragraphs => "paragraphs",
            Self::AuthStatus => "login.status",
        }
    }
}

/// Raw result of exactly one feed reducer operation/page in developer mode.
///
/// Unlike the production [`Feed`] methods, this does not follow
/// `next_cursor` automatically and returns JSON rather than typed items.
/// Comment results are validated against the production comment model.
/// It is intentionally exposed only as a diagnostic primitive.
pub struct DebugOperationPage {
    pub result: Value,
    pub next_cursor: Option<Value>,
}

impl JsOperation<'_> {
    fn operation_kind(&self) -> OperationKind {
        match self {
            Self::Search { .. } => OperationKind::Search,
            Self::BookInfo { .. } => OperationKind::BookInfo,
            Self::Chapters { .. } => OperationKind::Chapters,
            Self::Paragraphs { .. } => OperationKind::Paragraphs,
            Self::AuthStatus => OperationKind::AuthStatus,
            Self::Invoke { operation, .. } => *operation,
        }
    }

    fn handler(&self) -> JsMethodPath {
        self.operation_kind().handler()
    }
    fn kind(&self) -> &'static str {
        self.operation_kind().kind()
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
            Self::Invoke { input, .. } => (*input).clone(),
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
    client: FeedClient,
    has_login: bool,
    has_auth_status: bool,
    comment_support: (bool, bool),
    auth_info: RwLock<Option<AuthInfo>>,
    response_cache: AsyncMutex<HashMap<String, HttpResponse>>,
    webview_handler: RwLock<Option<SharedWebviewHandler>>,
    feed_object: JsObject,
}

impl std::fmt::Debug for JsFeed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // The realm state and the handler object have no useful Debug form;
        // tests only ever assert on the error side of the Result.
        f.debug_struct("JsFeed")
            .field("meta", &self.meta)
            .finish_non_exhaustive()
    }
}

/// The final outcome of an operation, separated from [`Step`] so the
/// per-round union does not leak into callers.
struct Complete {
    result: Value,
    next_cursor: Option<JsData>,
}

impl JsFeed {
    /// Run exactly one public feed operation with caller-provided JSON input
    /// and cursor. This is used by developer tooling; normal app code should
    /// use the typed [`Feed`] methods, which follow pagination automatically.
    pub async fn debug_operation_page(
        &self,
        operation: &str,
        input: Value,
        cursor: Value,
    ) -> Result<DebugOperationPage> {
        if !input.is_object() {
            return Err(Error::invalid_feed(
                "debug operation input must be an object",
            ));
        }
        let operation_kind = OperationKind::parse(operation)?;
        if matches!(operation_kind, OperationKind::AuthStatus) && !self.has_auth_status {
            return Err(Error::invalid_feed(
                "feed does not define the login.status operation",
            ));
        }
        let input = JsData::from_json(&input);
        let cursor = JsData::from_json(&cursor);
        let operation = JsOperation::Invoke {
            operation: operation_kind,
            input: &input,
        };
        let complete = self.run_operation(&operation, &cursor).await?;
        if matches!(
            operation_kind,
            OperationKind::ChapterComments | OperationKind::ParagraphComments
        ) {
            let items: Vec<crate::feed::comments::Comment> =
                serde_json::from_value(complete.result.clone())
                    .map_err(|e| Error::javascript(format!("invalid comment page: {e}")))?;
            validate_comment_page(&items)?;
        }
        Ok(DebugOperationPage {
            result: complete.result,
            next_cursor: complete.next_cursor.map(JsData::into_json),
        })
    }

    pub fn comment_support(&self) -> (bool, bool) {
        self.comment_support
    }

    /// Validate a comment target against the script's declared support and
    /// the contract's field caps, returning the operation it selects.
    /// Shared by the explicit page API and the pipeline stream so both
    /// reject the same targets.
    fn comment_operation(
        &self,
        query: &crate::feed::comments::CommentsQuery,
    ) -> Result<OperationKind> {
        let paragraph = query.paragraph_id.is_some();
        let supported = if paragraph {
            self.comment_support.1
        } else {
            self.comment_support.0
        };
        if !supported {
            return Err(Error::invalid_feed("comments are not supported"));
        }
        if query.book_id.is_empty()
            || query.chapter_id.is_empty()
            || query
                .paragraph_id
                .as_ref()
                .is_some_and(|s| s.is_empty() || s.len() > 4096)
            || query
                .parent_id
                .as_ref()
                .is_some_and(|s| s.is_empty() || s.len() > 4096)
        {
            return Err(Error::invalid_feed("invalid comment target"));
        }
        Ok(if paragraph {
            OperationKind::ParagraphComments
        } else {
            OperationKind::ChapterComments
        })
    }

    pub async fn comments_page(
        &self,
        query: &crate::feed::comments::CommentsQuery,
        cursor: Value,
    ) -> Result<crate::feed::comments::CommentPage> {
        use crate::feed::comments::CommentPage;
        let operation = self.comment_operation(query)?;
        if serde_json::to_vec(&cursor).map_or(true, |v| v.len() > MAX_CURSOR_BYTES) {
            return Err(Error::invalid_feed("comment cursor exceeds 4096 bytes"));
        }
        let input = comment_input(query);
        let complete = self
            .run_operation(
                &JsOperation::Invoke {
                    operation,
                    input: &input,
                },
                &JsData::from_json(&cursor),
            )
            .await?;
        let items: Vec<crate::feed::comments::Comment> = serde_json::from_value(complete.result)
            .map_err(|e| Error::javascript(format!("invalid comment page: {e}")))?;
        validate_comment_page(&items)?;
        let next_cursor = complete.next_cursor.map(JsData::into_json);
        if let Some(next) = &next_cursor
            && !cursor_advances(&cursor, next)
        {
            return Err(Error::invalid_feed(
                "comment cursor does not advance or exceeds limit",
            ));
        }
        Ok(CommentPage { items, next_cursor })
    }

    /// Stream every comment of one thread by following `next_cursor` — the
    /// pipeline form of the comments operations, for developer tooling. The
    /// production UI keeps [`crate::feed::comments::FeedComments`] so a
    /// panel can hold independent chapter, paragraph and reply cursors and
    /// retry a single page boundary.
    pub fn comments_stream(
        &self,
        query: crate::feed::comments::CommentsQuery,
    ) -> FeedStream<'_, crate::feed::comments::Comment> {
        Box::pin(stream! {
            let input = comment_input(&query);
            let operation = match self.comment_operation(&query) {
                Ok(operation) => JsOperation::Invoke {
                    operation,
                    input: &input,
                },
                Err(error) => {
                    yield Err(error);
                    return;
                }
            };
            let stream = self.paged_stream(operation, validate_comment_page);
            let mut stream = std::pin::pin!(stream);
            while let Some(result) = stream.next().await {
                yield result;
            }
        })
    }

    pub(crate) fn new(
        source: String,
        meta: FeedMeta,
        client: FeedClient,
        storage: Option<SharedStorageHandler>,
    ) -> Result<Self> {
        let meta_json =
            serde_json::to_string(&meta).map_err(|error| Error::javascript(error.to_string()))?;
        let mut sandbox = Sandbox::new(SCRIPT_TIMEOUT)?;
        if let Some(handler) = storage {
            sandbox.install_storage(handler, &meta.id)?;
        }
        sandbox.eval_script(&format!(
            "{PRELUDE}\nglobalThis.meta = Object.freeze({meta_json});"
        ))?;
        sandbox.eval_script(
            r#"Object.defineProperty(globalThis, "feed", {
                configurable: false,
                get() { return undefined; },
                set(_) {
                    throw new TypeError("globalThis.feed registration is not supported; export default the handler object instead");
                }
            });"#,
        )?;
        let feed_object = sandbox.eval_module_default(&source)?;
        sandbox.clear_storage_wiring()?;
        Self::require_handlers(&feed_object)?;
        let (has_login, has_auth_status) = Self::login_capabilities(&feed_object)?;

        let comment_support = feed_object.comment_handlers()?;
        Ok(Self {
            comment_support,
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
                "JavaScript feed must export default an object with {names} functions"
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

    /// Execute one feed HTTP request, retrying transient failures.
    ///
    /// Each attempt carries its own [`HTTP_TIMEOUT`] budget. An elapsed
    /// budget surfaces as a reqwest timeout error, which `is_retryable`
    /// classifies as transient, so a stalled gateway — connection accepted,
    /// no bytes — costs one attempt here and eventually fails honestly
    /// instead of hanging the operation until the host cancels it.
    async fn execute_http_with_retry(&self, request: &HttpRequest) -> Result<HttpResponse> {
        let mut attempt = 0u32;
        loop {
            match self
                .client
                .execute(&self.meta.id, request, HTTP_TIMEOUT)
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
        let Some(cache_key) = cache_key else {
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
        let outcome = self.drive_steps(operation, cursor).await;
        if let Err(error) = &outcome {
            tracing::warn!(
                feed_id = %self.meta.id,
                operation = operation.kind(),
                error = %error,
                "feed operation failed"
            );
        }
        outcome
    }

    /// The reducer loop: invoke the handler, execute the returned step, and
    /// repeat until the feed completes or fails.
    async fn drive_steps(&self, operation: &JsOperation<'_>, cursor: &JsData) -> Result<Complete> {
        // `state` threads opaque JavaScript values between rounds; the
        // executed step's result is carried as `outcome` and consumed by the
        // next round.
        let mut state: Option<OpaqueJsValue> = None;
        let mut outcome: Option<StepOutcome> = None;
        let mut steps_left = MAX_INTERNAL_STEPS;

        loop {
            let round_index = MAX_INTERNAL_STEPS - steps_left;
            tracing::debug!(
                feed_id = %self.meta.id,
                operation = operation.kind(),
                round = round_index,
                "invoking reducer"
            );
            let auth = self.auth_info()?;
            let round = Round {
                cursor,
                state: state.take(),
                outcome: outcome.take(),
                auth: auth.as_ref(),
            };
            let step = self.invoke(operation, round)?;
            let (kind, summary) = step_trace_description(&step);
            crate::step_trace::record(operation.kind(), round_index, kind, summary);
            match step {
                Step::Request {
                    request,
                    next_state,
                    cache_key,
                } => {
                    spend_step(&mut steps_left)?;
                    let request = self.apply_auth_patch(operation, request)?;
                    let http_response = if operation.kind().starts_with("comments.") {
                        // Comments are explicit pages and may depend on the
                        // current account. Never reuse a source's response
                        // cache key across comment requests or auth changes.
                        self.execute_http_with_retry(&request).await?
                    } else {
                        self.execute_cached_http(&request, cache_key.as_deref())
                            .await?
                    };
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
                    if !domain_allowed(&url, &self.meta.access_domains) {
                        return Err(Error::domain_not_allowed(
                            url,
                            self.meta.access_domains.clone(),
                        ));
                    }
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
                    result,
                    next_cursor,
                } => {
                    return Ok(Complete {
                        result,
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
        let items = serde_json::from_value(complete.result)
            .map_err(|error| Error::javascript(format!("invalid result: {error}")))?;
        Ok(Page {
            items,
            next_cursor: complete.next_cursor,
        })
    }

    async fn run_value<T: DeserializeOwned>(&self, operation: &JsOperation<'_>) -> Result<T> {
        let complete = self.run_operation(operation, &JsData::Null).await?;
        serde_json::from_value(complete.result)
            .map_err(|error| Error::javascript(format!("invalid value: {error}")))
    }

    /// The pagination engine: fetch pages, validate each one before any
    /// of its items flow, and follow `next_cursor` until it runs out.
    /// `validate_page` runs when a page arrives, so a page that violates
    /// the contract never yields a partial prefix — the stream form of
    /// the explicit page APIs' page-level rejection.
    fn paged_stream<'a, T, F>(
        &'a self,
        operation: JsOperation<'a>,
        validate_page: F,
    ) -> FeedStream<'a, T>
    where
        T: DeserializeOwned + Send + 'a,
        F: Fn(&[T]) -> Result<()> + Send + 'a,
    {
        Box::pin(stream! {
            let mut cursor = JsData::Null;
            let mut cursor_json = Value::Null;
            let mut pages = 0usize;
            loop {
                if pages >= MAX_PIPELINE_PAGES {
                    yield Err(Error::invalid_feed("pipeline page limit exceeded"));
                    break;
                }
                match self.run_page(&operation, &cursor).await {
                    Ok(page) => {
                        pages += 1;
                        if let Err(error) = validate_page(&page.items) {
                            yield Err(error);
                            break;
                        }
                        // Validate the page's cursor before yielding its
                        // items, mirroring `comments_page`'s page-level
                        // rejection; the original `JsData` still threads
                        // through unchanged.
                        let next = match page.next_cursor {
                            Some(value) => {
                                let next_json = value.clone().into_json();
                                if !cursor_advances(&cursor_json, &next_json) {
                                    yield Err(Error::invalid_feed(
                                        "pipeline cursor does not advance or exceeds limit",
                                    ));
                                    break;
                                }
                                cursor_json = next_json;
                                Some(value)
                            }
                            None => None,
                        };
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

    /// Search providers commonly repeat the tail item of the previous page.
    /// Keep the first stable book identity and continue pulling instead of
    /// turning a recoverable pagination overlap into a terminal stream error.
    fn unique_search_stream<'a>(
        &'a self,
        inner: FeedStream<'a, SearchResult>,
    ) -> FeedStream<'a, SearchResult> {
        Box::pin(stream! {
            let mut seen = HashSet::new();
            let mut inner = std::pin::pin!(inner);
            while let Some(result) = inner.next().await {
                match result {
                    Ok(item) => {
                        if seen.insert(item.id.clone()) {
                            yield Ok(item);
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
}

fn step_trace_description(step: &Step) -> (&'static str, String) {
    match step {
        Step::Request {
            request, cache_key, ..
        } => (
            "request",
            format!(
                "{} {}{}",
                request.method,
                crate::http::redact_url_secrets(&request.url),
                cache_key
                    .as_deref()
                    .map(|_| " · cache yes".to_owned())
                    .unwrap_or_default()
            ),
        ),
        Step::Compute {
            programs, input, ..
        } => (
            "compute",
            format!(
                "{} program(s) · {} input bytes",
                programs.len(),
                input.measure()
            ),
        ),
        Step::Webview { url, title, .. } => (
            "webview",
            title
                .as_deref()
                .map(|title| format!("{title} · {}", crate::http::redact_url_secrets(url)))
                .unwrap_or_else(|| crate::http::redact_url_secrets(url)),
        ),
        Step::Complete { result, .. } => (
            "complete",
            format!(
                "result: {}",
                match result {
                    Value::Object(_) => "object",
                    Value::Array(_) => "array",
                    Value::Null => "null",
                    Value::Bool(_) => "boolean",
                    Value::Number(_) => "number",
                    Value::String(_) => "string",
                }
            ),
        ),
        Step::Fail { code, message } => ("fail", format!("{code} · {message}")),
    }
}

/// Count one internal step, failing once the loop budget is spent.
fn spend_step(steps_left: &mut usize) -> Result<()> {
    *steps_left = steps_left
        .checked_sub(1)
        .ok_or_else(|| Error::javascript("feed operation exceeded the internal step limit"))?;
    Ok(())
}

/// A page's next cursor must advance pagination: it differs from the
/// cursor that produced the page and stays within [`MAX_CURSOR_BYTES`].
/// The explicit comments API and the automatic pipeline share the rule so
/// both reject the same runaway handlers.
fn cursor_advances(prev: &Value, next: &Value) -> bool {
    *next != *prev
        && serde_json::to_vec(next).is_ok_and(|encoded| encoded.len() <= MAX_CURSOR_BYTES)
}

/// The `event.input` object of a comments operation, shared by the
/// explicit page API and the pipeline stream.
fn comment_input(query: &crate::feed::comments::CommentsQuery) -> JsData {
    JsData::from_json(&serde_json::json!({
        "bookId": query.book_id, "chapterId": query.chapter_id,
        "paragraphId": query.paragraph_id, "parentId": query.parent_id,
    }))
}

/// One comments page carries at most 200 items whose fields stay within
/// the contract's caps. The explicit page API and the pipeline stream
/// share the rule so both reject the same oversized pages.
fn validate_comment_page(items: &[crate::feed::comments::Comment]) -> Result<()> {
    if items.len() > MAX_COMMENT_ITEMS_PER_PAGE
        || items.iter().any(|c| {
            c.id.is_empty()
                || c.id.len() > 4096
                || c.text.len() > 32768
                || c.author.name.len() > 1024
                || c.created_at_ms
                    .is_some_and(|t| !(0..=8_640_000_000_000_000).contains(&t))
                || c.author.avatar_url.as_ref().is_some_and(|v| v.len() > 8192)
        })
    {
        return Err(Error::invalid_feed(
            "comment page exceeds item or text limits",
        ));
    }
    Ok(())
}

/// One search page carries at most 200 results whose fields stay within
/// the contract's caps. Identifiers must be non-empty; the free-text
/// fields are length-capped but may be empty.
fn validate_search_page(items: &[SearchResult]) -> Result<()> {
    if items.len() > MAX_SEARCH_ITEMS_PER_PAGE
        || items.iter().any(|b| {
            b.id.is_empty()
                || b.id.len() > 4096
                || b.title.len() > 1024
                || b.author.len() > 1024
                || b.cover_url.as_ref().is_some_and(|v| v.len() > 8192)
                || b.description.as_ref().is_some_and(|v| v.len() > 32768)
        })
    {
        return Err(Error::invalid_feed(
            "search page exceeds item or field limits",
        ));
    }
    Ok(())
}

/// A book info object follows the same field caps as a search result;
/// its identifier must be non-empty.
fn validate_book_info(info: &BookInfo) -> Result<()> {
    if info.id.is_empty()
        || info.id.len() > 4096
        || info.title.len() > 1024
        || info.author.len() > 1024
        || info.cover_url.as_ref().is_some_and(|v| v.len() > 8192)
        || info.description.as_ref().is_some_and(|v| v.len() > 32768)
    {
        return Err(Error::invalid_feed("book info exceeds field limits"));
    }
    Ok(())
}

/// One directory page carries at most 10,000 entries: a full SSR table of
/// contents in a single `complete` is legitimate, so this budget sits far
/// above real directories while still bounding a runaway script.
fn validate_chapters_page(items: &[ChapterInfo]) -> Result<()> {
    if items.len() > MAX_CHAPTER_ITEMS_PER_PAGE
        || items
            .iter()
            .any(|c| c.id.is_empty() || c.id.len() > 4096 || c.title.len() > 1024)
    {
        return Err(Error::invalid_feed(
            "chapter page exceeds item or field limits",
        ));
    }
    Ok(())
}

/// One chapter page carries at most 2,000 paragraphs — a whole chapter
/// in a single `complete` — with per-variant field caps. Script-level ids
/// are optional (the host assigns one when absent) but must be non-empty
/// when given; image URLs locate a resource, so empty ones are rejected.
fn validate_paragraphs_page(items: &[RawParagraph]) -> Result<()> {
    let id_ok = |id: &Option<String>| id.as_ref().is_none_or(|s| !s.is_empty() && s.len() <= 4096);
    if items.len() > MAX_PARAGRAPH_ITEMS_PER_PAGE
        || items.iter().any(|paragraph| match paragraph {
            RawParagraph::Title { id, text, .. } => !id_ok(id) || text.len() > 1024,
            RawParagraph::Text { id, content, .. } => !id_ok(id) || content.len() > 32768,
            RawParagraph::Image { id, url, alt, .. } => {
                !id_ok(id)
                    || url.is_empty()
                    || url.len() > 8192
                    || alt.as_ref().is_some_and(|a| a.len() > 2048)
            }
        })
    {
        return Err(Error::invalid_feed(
            "paragraph page exceeds item or field limits",
        ));
    }
    Ok(())
}

impl Feed for JsFeed {
    fn search<'a>(&'a self, keyword: &'a str) -> FeedStream<'a, SearchResult> {
        let operation = JsOperation::Search { keyword };
        let stream = self.paged_stream(operation, validate_search_page);
        self.unique_search_stream(stream)
    }

    async fn book_info(&self, id: &str) -> Result<BookInfo> {
        let operation = JsOperation::BookInfo { book_id: id };
        let info: BookInfo = self.run_value(&operation).await?;
        validate_book_info(&info)?;
        Ok(info)
    }

    fn chapters<'a>(&'a self, book_id: &'a str) -> FeedStream<'a, ChapterInfo> {
        let operation = JsOperation::Chapters { book_id };
        let stream = self.paged_stream(operation, validate_chapters_page);
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
        let raw: FeedStream<'a, RawParagraph> =
            self.paged_stream(operation, validate_paragraphs_page);
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

    fn http_client(&self) -> &FeedClient {
        &self.client
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

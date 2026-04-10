use std::sync::RwLock;
use std::time::Duration;

use async_stream::stream;
use mlua::{FromLua, Lua, LuaSerdeExt, Value};
use reqwest::Client;
use serde::de::DeserializeOwned;
use tokio::time::sleep;

use crate::error::Result;
use crate::feed::{
    AuthEntry, AuthInfo, AuthPageContext, AuthStatus, Feed, FeedAuthFlow, FeedMeta, FeedStream,
    RequestPatchContext,
};
use crate::http::{self, HttpRequest, HttpResponse};
use crate::model::{BookInfo, ChapterInfo, Page, Paragraph, SearchResult};
use crate::script::LUA_SERIALIZE_OPTIONS;

// ---------------------------------------------------------------------------
// Retry configuration
// ---------------------------------------------------------------------------

/// Maximum number of retry attempts for a single page fetch.
const MAX_RETRIES: u32 = 3;

/// Base delay for exponential backoff.
const BASE_DELAY_MS: u64 = 200;

/// Multiplier applied to the delay on each successive retry.
const BACKOFF_MULTIPLIER: u64 = 3;

// ---------------------------------------------------------------------------
// Handler types
// ---------------------------------------------------------------------------

/// A pair of Lua functions for a single feed operation: one constructs an
/// [`HttpRequest`] descriptor, the other parses the [`HttpResponse`].
#[derive(Clone)]
pub(crate) struct HandlerPair {
    /// Builds an [`HttpRequest`] from the caller-supplied arguments.
    pub(crate) request: mlua::Function,
    /// Parses an [`HttpResponse`] into domain data.
    pub(crate) parse: mlua::Function,
}

/// All handler pairs extracted from a Lua feed script.
///
/// Created by [`ScriptEngine::load_feed`](crate::script::runtime::ScriptEngine::load_feed)
/// and stored inside [`LuaFeed`].
pub(crate) struct FeedHandlers {
    pub(crate) search: HandlerPair,
    pub(crate) book_info: HandlerPair,
    pub(crate) chapters: HandlerPair,
    pub(crate) paragraphs: HandlerPair,
    login: Option<LoginHandlers>,
}

/// Optional Lua login/auth handlers.
#[derive(Clone)]
struct LoginHandlers {
    entry: mlua::Function,
    parse: mlua::Function,
    patch_request: mlua::Function,
    status: Option<HandlerPair>,
}

#[derive(Clone)]
pub struct LuaSupportAuth {
    login: LoginHandlers,
}

impl LuaSupportAuth {
    fn login(&self) -> &LoginHandlers {
        &self.login
    }
}

impl FromLua for HandlerPair {
    fn from_lua(value: Value, lua: &Lua) -> mlua::Result<Self> {
        let table = mlua::Table::from_lua(value, lua)?;
        let request: mlua::Function = table.get("request")?;
        let parse: mlua::Function = table.get("parse")?;
        Ok(HandlerPair { request, parse })
    }
}

impl FromLua for LoginHandlers {
    fn from_lua(value: Value, lua: &Lua) -> mlua::Result<Self> {
        let table = mlua::Table::from_lua(value, lua)?;
        let entry: mlua::Function = table.get("entry")?;
        let parse: mlua::Function = table.get("parse")?;
        let patch_request: mlua::Function = table.get("patch_request")?;
        let status: Option<HandlerPair> = match table.get::<Value>("status")? {
            Value::Nil => None,
            value => Some(HandlerPair::from_lua(value, lua)?),
        };
        Ok(LoginHandlers {
            entry,
            parse,
            patch_request,
            status,
        })
    }
}

impl FromLua for FeedHandlers {
    fn from_lua(value: Value, lua: &Lua) -> mlua::Result<Self> {
        let table = mlua::Table::from_lua(value, lua)?;

        let login: Option<LoginHandlers> = match table.get::<Value>("login")? {
            Value::Nil => None,
            value => Some(LoginHandlers::from_lua(value, lua)?),
        };

        Ok(Self {
            search: HandlerPair::from_lua(table.get("search")?, lua)?,
            book_info: HandlerPair::from_lua(table.get("book_info")?, lua)?,
            chapters: HandlerPair::from_lua(table.get("chapters")?, lua)?,
            paragraphs: HandlerPair::from_lua(table.get("paragraphs")?, lua)?,
            login,
        })
    }
}

// ---------------------------------------------------------------------------
// FromLua for Page<T, Value>
// ---------------------------------------------------------------------------

impl<T: DeserializeOwned> FromLua for Page<T, Value> {
    fn from_lua(value: Value, lua: &Lua) -> mlua::Result<Self> {
        let table = mlua::Table::from_lua(value, lua)?;

        let items_value: Value = table.get("items")?;
        let items: Vec<T> = lua.from_value(items_value)?;

        let next_cursor: Value = table.get("next_cursor")?;
        let next_cursor = (!next_cursor.is_nil()).then_some(next_cursor);

        Ok(Page { items, next_cursor })
    }
}

// ---------------------------------------------------------------------------
// LuaFeed
// ---------------------------------------------------------------------------

/// A [`Feed`] implementation backed by a Lua script.
///
/// Created by [`ScriptEngine::load_feed`](crate::script::runtime::ScriptEngine::load_feed).
///
/// Wrap in `Arc<LuaFeed>` to share a single compiled feed across concurrent
/// requests without reloading the script on every call.
pub struct LuaFeed {
    lua: Lua,
    handlers: FeedHandlers,
    meta: FeedMeta,
    /// `reqwest::Client` is already `Arc`-backed internally; storing it
    /// directly avoids a redundant double-indirection.
    client: Client,
    auth_info: RwLock<Option<AuthInfo>>,
}

impl LuaFeed {
    /// Create a new `LuaFeed`. Called internally by `ScriptEngine`.
    pub(crate) fn new(lua: Lua, handlers: FeedHandlers, meta: FeedMeta, client: Client) -> Self {
        Self {
            lua,
            handlers,
            meta,
            client,
            auth_info: RwLock::new(None),
        }
    }

    // -----------------------------------------------------------------------
    // Core request → HTTP → parse cycle
    // -----------------------------------------------------------------------

    /// Execute a full request/parse cycle for paginated results:
    /// 1. Call `pair.request` to get an [`HttpRequest`] descriptor.
    /// 2. Execute the HTTP request via `reqwest`.
    /// 3. Call `pair.parse` with the [`HttpResponse`] and convert the result
    ///    into a [`Page<T, Value>`] via its [`FromLua`] implementation.
    async fn execute_paged_cycle<T: DeserializeOwned>(
        &self,
        pair: &HandlerPair,
        args: impl mlua::IntoLuaMulti,
        patch_context: &RequestPatchContext,
    ) -> Result<Page<T, Value>> {
        let http_request: HttpRequest = self.call_function(&pair.request, args)?;
        let http_request = self.apply_auth_patch(patch_context, http_request)?;
        let http_response = self.execute_http(&http_request).await?;
        let lua_response = self
            .lua
            .to_value_with(&http_response, LUA_SERIALIZE_OPTIONS)?;
        let page: Page<T, Value> = pair.parse.call(lua_response)?;
        Ok(page)
    }

    /// Execute a full request/parse cycle with exponential-backoff retry,
    /// where request arguments are produced dynamically for each retry.
    async fn execute_paged_cycle_with_retry_by<T, A, F>(
        &self,
        pair: &HandlerPair,
        mut make_args: F,
        patch_context: &RequestPatchContext,
    ) -> Result<Page<T, Value>>
    where
        T: DeserializeOwned,
        A: mlua::IntoLuaMulti + Send,
        F: FnMut() -> A,
    {
        let mut attempt = 0u32;
        loop {
            match self
                .execute_paged_cycle(pair, make_args(), patch_context)
                .await
            {
                Ok(page) => {
                    if attempt > 0 {
                        tracing::info!(
                            feed_id = %self.meta.id,
                            retried_count = attempt,
                            "paged request succeeded after retries"
                        );
                    }
                    return Ok(page);
                }
                Err(err) if attempt < MAX_RETRIES && err.is_retryable() => {
                    let delay_ms = BASE_DELAY_MS * BACKOFF_MULTIPLIER.pow(attempt);
                    tracing::warn!(
                        feed_id = %self.meta.id,
                        retried_count = attempt + 1,
                        delay_ms,
                        error = %err,
                        "retryable paged request failed; retrying"
                    );
                    sleep(Duration::from_millis(delay_ms)).await;
                    attempt += 1;
                }
                Err(err) => {
                    tracing::error!(
                        feed_id = %self.meta.id,
                        retried_count = attempt,
                        error = %err,
                        "paged request failed"
                    );
                    return Err(err);
                }
            }
        }
    }

    /// Execute a full request/parse cycle for non-paginated results.
    async fn execute_cycle<T: DeserializeOwned>(
        &self,
        pair: &HandlerPair,
        args: impl mlua::IntoLuaMulti,
        patch_context: &RequestPatchContext,
    ) -> Result<T> {
        let http_request: HttpRequest = self.call_function(&pair.request, args)?;
        let http_request = self.apply_auth_patch(patch_context, http_request)?;
        let http_response = self.execute_http(&http_request).await?;
        let lua_response = self
            .lua
            .to_value_with(&http_response, LUA_SERIALIZE_OPTIONS)?;
        let value: Value = pair.parse.call(lua_response)?;
        let result: T = self.lua.from_value(value)?;
        Ok(result)
    }

    /// Call a Lua function and deserialize its return value via serde.
    fn call_function<T: DeserializeOwned>(
        &self,
        func: &mlua::Function,
        args: impl mlua::IntoLuaMulti,
    ) -> Result<T> {
        let value: Value = func.call(args)?;
        let result: T = self.lua.from_value(value)?;
        Ok(result)
    }

    // -----------------------------------------------------------------------
    // Paginated stream helper
    // -----------------------------------------------------------------------

    /// Build a [`FeedStream`] that automatically follows pagination cursors,
    /// yielding individual items one by one.
    ///
    /// `make_args` receives the current cursor and returns the argument tuple
    /// for the Lua `request` function.
    fn paged_stream_by<'a, T, A, F>(
        &'a self,
        pair: &'a HandlerPair,
        patch_context: RequestPatchContext,
        mut make_args: F,
    ) -> FeedStream<'a, T>
    where
        T: DeserializeOwned + Send + 'a,
        A: mlua::IntoLuaMulti + Send,
        F: FnMut(&Value) -> A + Send + 'a,
    {
        Box::pin(stream! {
            let mut cursor = Value::Nil;
            loop {
                match self
                    .execute_paged_cycle_with_retry_by(pair, || make_args(&cursor), &patch_context)
                    .await
                {
                    Ok(page) => {
                        let next = page.next_cursor;
                        for item in page.items {
                            yield Ok(item);
                        }
                        match next {
                            Some(c) => cursor = c,
                            None => break,
                        }
                    }
                    Err(err) => {
                        yield Err(err);
                        break;
                    }
                }
            }
        })
    }

    fn apply_auth_patch(
        &self,
        context: &RequestPatchContext,
        request: HttpRequest,
    ) -> Result<HttpRequest> {
        let Some(login) = &self.handlers.login else {
            return Ok(request);
        };

        let auth_info = {
            let guard = self
                .auth_info
                .read()
                .map_err(|_| crate::error::Error::invalid_feed("auth state lock poisoned"))?;
            guard.clone()
        };

        let Some(auth_info) = auth_info else {
            return Ok(request);
        };

        let context_value = self.lua.to_value_with(context, LUA_SERIALIZE_OPTIONS)?;
        let request_value = self.lua.to_value_with(&request, LUA_SERIALIZE_OPTIONS)?;
        let auth_value = self.lua.to_value_with(&auth_info, LUA_SERIALIZE_OPTIONS)?;

        let value: Value = login
            .patch_request
            .call((context_value, request_value, auth_value))?;
        let patched: HttpRequest = self.lua.from_value(value)?;
        Ok(patched)
    }

    // -----------------------------------------------------------------------
    // HTTP helpers (delegated to crate::http)
    // -----------------------------------------------------------------------

    async fn execute_http(&self, req: &HttpRequest) -> Result<HttpResponse> {
        http::execute(&self.client, &self.meta.id, &self.meta.access_domains, req).await
    }
}

// ---------------------------------------------------------------------------
// Feed trait implementation
// ---------------------------------------------------------------------------

impl Feed for LuaFeed {
    fn search<'a>(&'a self, keyword: &'a str) -> FeedStream<'a, SearchResult> {
        let patch_context = RequestPatchContext::Search {
            feed_id: self.meta.id.clone(),
        };
        self.paged_stream_by(&self.handlers.search, patch_context, move |cursor| {
            (keyword, cursor.clone())
        })
    }

    async fn book_info(&self, id: &str) -> Result<BookInfo> {
        let patch_context = RequestPatchContext::BookInfo {
            feed_id: self.meta.id.clone(),
            book_id: id.to_owned(),
        };
        self.execute_cycle(&self.handlers.book_info, id, &patch_context)
            .await
    }

    fn chapters<'a>(&'a self, book_id: &'a str) -> FeedStream<'a, ChapterInfo> {
        let patch_context = RequestPatchContext::Chapters {
            feed_id: self.meta.id.clone(),
            book_id: book_id.to_owned(),
        };
        self.paged_stream_by(&self.handlers.chapters, patch_context, move |cursor| {
            (book_id, cursor.clone())
        })
    }

    fn paragraphs<'a>(
        &'a self,
        book_id: &'a str,
        chapter_id: &'a str,
    ) -> FeedStream<'a, Paragraph> {
        let patch_context = RequestPatchContext::Paragraphs {
            feed_id: self.meta.id.clone(),
            book_id: book_id.to_owned(),
            chapter_id: chapter_id.to_owned(),
        };
        self.paged_stream_by(&self.handlers.paragraphs, patch_context, move |cursor| {
            (book_id, chapter_id, cursor.clone())
        })
    }

    fn meta(&self) -> &FeedMeta {
        &self.meta
    }
}

impl FeedAuthFlow for LuaFeed {
    type SupportAuth = LuaSupportAuth;

    fn supports_auth(&self) -> Option<Self::SupportAuth> {
        self.handlers
            .login
            .clone()
            .map(|login| LuaSupportAuth { login })
    }

    fn auth_entry(&self, support: &Self::SupportAuth) -> Result<AuthEntry> {
        let value: Value = support.login().entry.call(())?;
        let entry: AuthEntry = self.lua.from_value(value)?;
        Ok(entry)
    }

    fn parse_auth(&self, support: &Self::SupportAuth, page: &AuthPageContext) -> Result<AuthInfo> {
        let page_value = self.lua.to_value_with(page, LUA_SERIALIZE_OPTIONS)?;
        let value: Value = support.login().parse.call(page_value)?;
        let auth_info: AuthInfo = self.lua.from_value(value)?;
        Ok(auth_info)
    }

    fn set_auth_info(
        &self,
        _support: &Self::SupportAuth,
        auth_info: Option<AuthInfo>,
    ) -> Result<()> {
        let mut guard = self
            .auth_info
            .write()
            .map_err(|_| crate::error::Error::invalid_feed("auth state lock poisoned"))?;
        *guard = auth_info;
        Ok(())
    }

    async fn auth_status(&self, support: &Self::SupportAuth) -> Result<AuthStatus> {
        let has_auth = {
            let guard = self
                .auth_info
                .read()
                .map_err(|_| crate::error::Error::invalid_feed("auth state lock poisoned"))?;
            guard.is_some()
        };

        if !has_auth {
            return Ok(AuthStatus::LoggedOut);
        }

        if let Some(status_pair) = &support.login().status {
            let context = RequestPatchContext::AuthStatus {
                feed_id: self.meta.id.clone(),
            };
            let is_valid: bool = self.execute_cycle(status_pair, (), &context).await?;
            return Ok(if is_valid {
                AuthStatus::LoggedIn
            } else {
                AuthStatus::Expired
            });
        }

        Err(crate::error::Error::auth_status_not_supported(
            &self.meta.id,
        ))
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use tokio_stream::StreamExt as _;

    use super::*;
    use crate::error::{Error, ScriptError};
    use crate::script::runtime::ScriptEngine;

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    /// Build a minimal feed script header with the given `base_url`.
    fn make_header(base_url: &str) -> String {
        format!(
            r#"-- ==Feed==
-- @id          test-feed
-- @name        Test Feed
-- @version     1.0
-- @base_url    {base_url}
-- @schema_version 1
-- ==/Feed==
"#
        )
    }

    /// A Lua script body that:
    /// - `search.request(keyword, cursor)` → GET `meta.base_url/search?q=<keyword>&cursor=<cursor>`
    /// - `search.parse(resp)` → decodes JSON body via `@langhuan/json`
    /// - All other handlers are stubs that return empty pages / empty objects.
    const SEARCH_BODY: &str = r#"
local json = require("@langhuan/json")
return {
    search = {
        request = function(keyword, cursor)
            -- Use the `params` field so reqwest encodes the query string
            -- correctly and mockito can match the path `/search` cleanly.
            local params = { q = keyword }
            if cursor ~= nil then
                params.cursor = tostring(cursor)
            end
            return { url = meta.base_url .. "/search", method = "GET", params = params }
        end,
        parse = function(resp)
            return json.decode(resp.body)
        end,
    },
    book_info = {
        request = function(id) return { url = meta.base_url .. "/book/" .. id } end,
        parse   = function(resp) return json.decode(resp.body) end,
    },
    chapters = {
        request = function(book_id, cursor) return { url = meta.base_url .. "/chapters/" .. book_id } end,
        parse   = function(resp) return { items = {}, next_cursor = nil } end,
    },
    paragraphs = {
        request = function(book_id, chapter_id, cursor) return { url = meta.base_url .. "/content/" .. chapter_id } end,
        parse   = function(resp) return { items = {}, next_cursor = nil } end,
    },
}
"#;

    /// A Lua script body whose `search.parse` always raises a Lua error.
    const PARSE_ERROR_BODY: &str = r#"
return {
    search = {
        request = function(keyword, cursor)
            return { url = meta.base_url .. "/search" }
        end,
        parse = function(resp)
            error("intentional parse failure")
        end,
    },
    book_info = {
        request = function(id) return { url = meta.base_url .. "/book/" .. id } end,
        parse   = function(resp) error("stub") end,
    },
    chapters = {
        request = function(book_id, cursor) return { url = meta.base_url .. "/chapters/" .. book_id } end,
        parse   = function(resp) return { items = {}, next_cursor = nil } end,
    },
    paragraphs = {
        request = function(book_id, chapter_id, cursor) return { url = meta.base_url .. "/content/" .. chapter_id } end,
        parse   = function(resp) return { items = {}, next_cursor = nil } end,
    },
}
"#;

    /// A Lua script body using `@langhuan/html` to parse search result HTML.
    const HTML_SEARCH_BODY: &str = r#"
local html = require("@langhuan/html")

return {
    search = {
        request = function(keyword, cursor)
            return { url = meta.base_url .. "/search" }
        end,
        parse = function(resp)
            local doc = html.parse(resp.body)
            local nodes = doc:select("ul.books li.item a.book")
            local items = {}

            for i = 1, #nodes do
                local node = nodes[i]
                local href = node:attr("href") or ""
                local id = href:match("/book/(%d+)%.html")
                if id then
                    table.insert(items, {
                        id = id,
                        title = node:text(),
                        author = "Unknown",
                    })
                end
            end

            return { items = items, next_cursor = nil }
        end,
    },
    book_info = {
        request = function(id) return { url = meta.base_url .. "/book/" .. id } end,
        parse   = function(resp) return { id = "0", title = "", author = "" } end,
    },
    chapters = {
        request = function(book_id, cursor) return { url = meta.base_url .. "/chapters/" .. book_id } end,
        parse   = function(resp) return { items = {}, next_cursor = nil } end,
    },
    paragraphs = {
        request = function(book_id, chapter_id, cursor) return { url = meta.base_url .. "/content/" .. chapter_id } end,
        parse   = function(resp) return { items = {}, next_cursor = nil } end,
    },
}
"#;

    /// Load a `LuaFeed` from the given script body, injecting `base_url` into
    /// the `==Feed==` header so Lua can reference it via `meta.base_url`.
    async fn load_feed(base_url: &str, body: &str) -> LuaFeed {
        let script = format!("{}{}", make_header(base_url), body);
        ScriptEngine::new()
            .load_feed(&script)
            .await
            .expect("script should load without error")
    }

    // -----------------------------------------------------------------------
    // Tests: json null → Lua nil (isolated, no HTTP)
    // -----------------------------------------------------------------------

    /// Verify that `json.decode` converts JSON `null` to Lua `nil`, so that
    /// `FromLua for Page` terminates pagination correctly.
    #[tokio::test]
    async fn json_null_becomes_lua_nil_in_page() {
        use crate::script::runtime::ScriptEngine;
        use tokio_stream::StreamExt as _;

        // A feed whose parse function returns a hard-coded page with
        // next_cursor = json null, decoded via @langhuan/json.
        // The request function returns a URL that the mock server will serve.
        let mut server = mockito::Server::new_async().await;
        let _mock = server
            .mock("GET", mockito::Matcher::Regex(r"^/".into()))
            .with_status(200)
            .with_body(r#"{"items":[{"id":"x","title":"T","author":"A"}],"next_cursor":null}"#)
            .create_async()
            .await;

        let script = format!(
            r#"{}local json = require("@langhuan/json")
return {{
    search = {{
        request = function(k, c) return {{ url = meta.base_url .. "/" }} end,
        parse   = function(r) return json.decode(r.body) end,
    }},
    book_info     = {{ request = function(id) return {{ url = meta.base_url }} end, parse = function(r) return {{}} end }},
    chapters      = {{ request = function(id, c) return {{ url = meta.base_url }} end, parse = function(r) return {{ items = {{}}, next_cursor = nil }} end }},
    paragraphs = {{ request = function(book_id, chapter_id, c) return {{ url = meta.base_url }} end, parse = function(r) return {{ items = {{}}, next_cursor = nil }} end }},
}}
"#,
            make_header(&server.url())
        );

        let feed = ScriptEngine::new().load_feed(&script).await.expect("load");

        // Should yield exactly 1 item and then stop (next_cursor was null).
        let results: Vec<_> = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            feed.search("x").collect::<Vec<_>>(),
        )
        .await
        .expect("stream must finish within 5 seconds");

        assert_eq!(results.len(), 1);
        assert_eq!(results[0].as_ref().unwrap().id, "x");
    }

    // -----------------------------------------------------------------------
    // Tests: single-page search
    // -----------------------------------------------------------------------

    /// A single-page response with two items and `next_cursor = nil` should
    /// yield exactly those two items and then close the stream.
    #[tokio::test]
    async fn single_page_search_yields_all_items() {
        let mut server = mockito::Server::new_async().await;
        // No Content-Type header: body is returned as plain text, so
        // `json.decode(resp.body)` in SEARCH_BODY works correctly.
        let _mock = server
            .mock("GET", mockito::Matcher::Regex(r"^/search(\?.*)?$".into()))
            .with_status(200)
            .with_body(
                r#"{"items":[{"id":"1","title":"Rust Book","author":"Steve"},{"id":"2","title":"Async Rust","author":"Alice"}],"next_cursor":null}"#,
            )
            .create_async()
            .await;

        let feed = load_feed(&server.url(), SEARCH_BODY).await;
        let results: Vec<_> = feed.search("rust").collect::<Vec<_>>().await;

        assert_eq!(results.len(), 2, "expected 2 items from single page");
        let first = results[0].as_ref().expect("first item should be Ok");
        assert_eq!(first.id, "1");
        assert_eq!(first.title, "Rust Book");
        let second = results[1].as_ref().expect("second item should be Ok");
        assert_eq!(second.id, "2");
        assert_eq!(second.title, "Async Rust");
    }

    // -----------------------------------------------------------------------
    // Tests: multi-page search (cursor following)
    // -----------------------------------------------------------------------

    /// A two-page response: first page returns `next_cursor = "page2"`, second
    /// page returns `next_cursor = nil`.  The stream should yield all 3 items.
    #[tokio::test]
    async fn multi_page_search_follows_cursor() {
        let mut server = mockito::Server::new_async().await;

        // mockito matches `path_and_query` together, so we embed the query
        // condition in the path Regex.  More-specific mock (with cursor) is
        // registered first; mockito checks mocks in reverse registration
        // order, so it takes priority over the fallback below.
        let _mock2 = server
            .mock("GET", mockito::Matcher::Regex(r"^/search\?.*cursor=page2".into()))
            .with_status(200)
            .with_body(
                r#"{"items":[{"id":"2","title":"Book Two","author":"B"},{"id":"3","title":"Book Three","author":"C"}],"next_cursor":null}"#,
            )
            .create_async()
            .await;

        // Fallback: first page — matches any /search request (no cursor).
        let _mock1 = server
            .mock("GET", mockito::Matcher::Regex(r"^/search(\?.*)?$".into()))
            .with_status(200)
            .with_body(
                r#"{"items":[{"id":"1","title":"Book One","author":"A"}],"next_cursor":"page2"}"#,
            )
            .create_async()
            .await;

        let feed = load_feed(&server.url(), SEARCH_BODY).await;
        let results: Vec<_> = feed.search("book").collect::<Vec<_>>().await;

        assert_eq!(results.len(), 3, "expected 3 items across 2 pages");
        assert_eq!(results[0].as_ref().unwrap().id, "1");
        assert_eq!(results[1].as_ref().unwrap().id, "2");
        assert_eq!(results[2].as_ref().unwrap().id, "3");
    }

    // -----------------------------------------------------------------------
    // Tests: Lua parse error terminates stream
    // -----------------------------------------------------------------------

    /// When the Lua `parse` function raises an error, the stream should yield
    /// a single `Err(Error::Lua(_))` and then close.
    #[tokio::test]
    async fn stream_terminates_on_lua_parse_error() {
        let mut server = mockito::Server::new_async().await;
        let _mock = server
            .mock("GET", "/search")
            .with_status(200)
            .with_body("{}")
            .create_async()
            .await;

        let feed = load_feed(&server.url(), PARSE_ERROR_BODY).await;
        let results: Vec<_> = feed.search("anything").collect::<Vec<_>>().await;

        assert_eq!(results.len(), 1, "expected exactly one error item");
        assert!(
            matches!(results[0], Err(Error::Script(ScriptError::Lua(_)))),
            "expected Lua error, got: {:?}",
            results[0]
        );
    }

    /// Verify `@langhuan/html` is available in the sandboxed VM and can parse
    /// HTML in the normal feed execution path.
    #[tokio::test]
    async fn html_module_works_in_feed_search_parse() {
        let mut server = mockito::Server::new_async().await;
        let _mock = server
            .mock("GET", "/search")
            .with_status(200)
            .with_body(
                r#"
                <ul class="books">
                  <li class="item"><a class="book" href="/book/11.html"> Book One </a></li>
                  <li class="item"><a class="book" href="/book/22.html">Book Two</a></li>
                </ul>
                "#,
            )
            .create_async()
            .await;

        let feed = load_feed(&server.url(), HTML_SEARCH_BODY).await;
        let results: Vec<_> = feed.search("ignored").collect::<Vec<_>>().await;

        assert_eq!(results.len(), 2, "expected 2 items from html parse");
        assert_eq!(results[0].as_ref().unwrap().id, "11");
        assert_eq!(results[0].as_ref().unwrap().title, "Book One");
        assert_eq!(results[1].as_ref().unwrap().id, "22");
        assert_eq!(results[1].as_ref().unwrap().title, "Book Two");
    }

    // -----------------------------------------------------------------------
    // Auth / login tests
    // -----------------------------------------------------------------------

    const AUTH_STUBS: &str = "\
    search     = { request = function(k, c) return { url = meta.base_url .. \"/\" } end, parse = function(r) return { items = {}, next_cursor = nil } end },\n\
    book_info  = { request = function(id)   return { url = meta.base_url .. \"/\" } end, parse = function(r) return { id = \"\", title = \"\", author = \"\" } end },\n\
    chapters   = { request = function(id, c) return { url = meta.base_url .. \"/\" } end, parse = function(r) return { items = {}, next_cursor = nil } end },\n\
    paragraphs = { request = function(b, c, cur) return { url = meta.base_url .. \"/\" } end, parse = function(r) return { items = {}, next_cursor = nil } end },\n";

    fn make_login_script_no_status(base_url: &str) -> String {
        format!(
            "{header}\nreturn {{\n{stubs}\n    login = {{\n        entry         = function() return {{ url = meta.base_url .. \"/login\" }} end,\n        parse         = function(page) return {{ token = page.current_url }} end,\n        patch_request = function(ctx, req, auth) return req end,\n    }},\n}}\n",
            header = make_header(base_url),
            stubs = AUTH_STUBS,
        )
    }

    fn make_login_script_with_status(base_url: &str, status_result: bool) -> String {
        let status_val = if status_result { "true" } else { "false" };
        format!(
            "{header}\nreturn {{\n{stubs}\n    login = {{\n        entry         = function() return {{ url = meta.base_url .. \"/login\" }} end,\n        parse         = function(page) return {{ token = \"tok\" }} end,\n        patch_request = function(ctx, req, auth) return req end,\n        status = {{\n            request = function() return {{ url = meta.base_url .. \"/status\" }} end,\n            parse   = function(resp) return {status_val} end,\n        }},\n    }},\n}}\n",
            header = make_header(base_url),
            stubs = AUTH_STUBS,
            status_val = status_val,
        )
    }

    /// A feed without a `login` block should return `None` from `supports_auth`.
    #[tokio::test]
    async fn supports_auth_returns_none_without_login_block() {
        let feed = load_feed("http://localhost", SEARCH_BODY).await;
        assert!(feed.supports_auth().is_none());
    }

    /// A feed with a `login` block should return `Some` from `supports_auth`.
    #[tokio::test]
    async fn supports_auth_returns_some_with_login_block() {
        let feed = ScriptEngine::new()
            .load_feed(&make_login_script_no_status("http://localhost"))
            .await
            .expect("load");
        assert!(feed.supports_auth().is_some());
    }

    /// Without any stored `auth_info`, `auth_status` must return `LoggedOut`.
    #[tokio::test]
    async fn auth_status_logged_out_when_no_auth_info() {
        let feed = ScriptEngine::new()
            .load_feed(&make_login_script_no_status("http://localhost"))
            .await
            .expect("load");
        let support = feed.supports_auth().expect("login block present");
        let status = feed.auth_status(&support).await.expect("auth_status ok");
        assert_eq!(status, AuthStatus::LoggedOut);
    }

    /// With stored `auth_info` but no `status` handler, `auth_status` must
    /// return an `AuthStatusNotSupported` error.
    #[tokio::test]
    async fn auth_status_not_supported_without_status_handler() {
        let feed = ScriptEngine::new()
            .load_feed(&make_login_script_no_status("http://localhost"))
            .await
            .expect("load");
        let support = feed.supports_auth().expect("login block present");
        feed.set_auth_info(&support, Some(serde_json::json!({"token": "abc"})))
            .expect("set_auth_info ok");
        let err = feed
            .auth_status(&support)
            .await
            .expect_err("should return error when status handler absent");
        assert!(
            matches!(
                err,
                crate::error::Error::Script(
                    crate::error::ScriptError::AuthStatusNotSupported { .. }
                )
            ),
            "expected AuthStatusNotSupported, got: {err:?}",
        );
    }

    /// When the `status.parse` handler returns `true`, `auth_status` must
    /// return `LoggedIn`.
    #[tokio::test]
    async fn auth_status_logged_in_when_status_returns_true() {
        let mut server = mockito::Server::new_async().await;
        let _mock = server
            .mock("GET", "/status")
            .with_status(200)
            .with_body("{}")
            .create_async()
            .await;

        let feed = ScriptEngine::new()
            .load_feed(&make_login_script_with_status(&server.url(), true))
            .await
            .expect("load");
        let support = feed.supports_auth().expect("login block present");
        feed.set_auth_info(&support, Some(serde_json::json!({"token": "abc"})))
            .expect("set_auth_info ok");
        let status = feed.auth_status(&support).await.expect("auth_status ok");
        assert_eq!(status, AuthStatus::LoggedIn);
    }

    /// When the `status.parse` handler returns `false`, `auth_status` must
    /// return `Expired`.
    #[tokio::test]
    async fn auth_status_expired_when_status_returns_false() {
        let mut server = mockito::Server::new_async().await;
        let _mock = server
            .mock("GET", "/status")
            .with_status(200)
            .with_body("{}")
            .create_async()
            .await;

        let feed = ScriptEngine::new()
            .load_feed(&make_login_script_with_status(&server.url(), false))
            .await
            .expect("load");
        let support = feed.supports_auth().expect("login block present");
        feed.set_auth_info(&support, Some(serde_json::json!({"token": "abc"})))
            .expect("set_auth_info ok");
        let status = feed.auth_status(&support).await.expect("auth_status ok");
        assert_eq!(status, AuthStatus::Expired);
    }

    /// `auth_entry` must return the URL produced by the Lua `entry` function.
    #[tokio::test]
    async fn auth_entry_returns_url_from_lua() {
        let feed = ScriptEngine::new()
            .load_feed(&make_login_script_no_status("http://example.com"))
            .await
            .expect("load");
        let support = feed.supports_auth().expect("login block present");
        let entry = feed.auth_entry(&support).expect("auth_entry ok");
        assert_eq!(entry.url, "http://example.com/login");
    }

    /// `parse_auth` must pass the page context to Lua and return the parsed
    /// `AuthInfo` map.
    #[tokio::test]
    async fn parse_auth_extracts_token_from_page() {
        let feed = ScriptEngine::new()
            .load_feed(&make_login_script_no_status("http://localhost"))
            .await
            .expect("load");
        let support = feed.supports_auth().expect("login block present");
        let page = AuthPageContext {
            current_url: "http://localhost/callback?code=XYZ".to_owned(),
            response: Default::default(),
            response_headers: vec![],
            cookies: vec![],
        };
        let auth_info = feed.parse_auth(&support, &page).expect("parse_auth ok");
        assert_eq!(
            auth_info.get("token").and_then(|v| v.as_str()),
            Some("http://localhost/callback?code=XYZ"),
        );
    }
}

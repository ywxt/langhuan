use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use async_stream::stream;
use mlua::{FromLua, Lua, LuaSerdeExt, Value};
use reqwest::Client;
use serde::de::DeserializeOwned;
use tokio::time::sleep;

use crate::error::Result;
use crate::feed::{Feed, FeedStream};
use crate::model::{
    BookInfo, ChapterContent, ChapterInfo, HttpRequest, HttpResponse, Page, SearchResult,
};
use crate::script::meta::FeedMeta;

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
pub(crate) struct HandlerPair {
    /// Builds an [`HttpRequest`] from the caller-supplied arguments.
    pub request: mlua::Function,
    /// Parses an [`HttpResponse`] into domain data.
    pub parse: mlua::Function,
}

/// All handler pairs extracted from a Lua feed script.
///
/// Created by [`ScriptEngine::load_feed`](super::engine::ScriptEngine::load_feed)
/// and stored inside [`LuaFeed`].
pub(crate) struct FeedHandlers {
    pub search: HandlerPair,
    pub book_info: HandlerPair,
    pub chapters: HandlerPair,
    pub chapter_content: HandlerPair,
}

/// Extract a [`HandlerPair`] (`request` + `parse`) from a Lua sub-table.
///
/// Returns `Error::MissingFunction` if either key is missing or not a function.
fn extract_pair(table: &mlua::Table, group: &str) -> mlua::Result<HandlerPair> {
    let sub: mlua::Table = table.get(group)?;
    let request: mlua::Function = sub.get("request")?;
    let parse: mlua::Function = sub.get("parse")?;
    Ok(HandlerPair { request, parse })
}

impl FromLua for FeedHandlers {
    fn from_lua(value: Value, lua: &Lua) -> mlua::Result<Self> {
        let table = mlua::Table::from_lua(value, lua)?;

        Ok(Self {
            search: extract_pair(&table, "search")?,
            book_info: extract_pair(&table, "book_info")?,
            chapters: extract_pair(&table, "chapters")?,
            chapter_content: extract_pair(&table, "chapter_content")?,
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
/// Created by [`ScriptEngine::load_feed`](super::engine::ScriptEngine::load_feed).
pub struct LuaFeed {
    lua: Lua,
    handlers: FeedHandlers,
    meta: FeedMeta,
    client: Arc<Client>,
}

impl LuaFeed {
    /// Create a new `LuaFeed`. Called internally by `ScriptEngine`.
    pub(crate) fn new(
        lua: Lua,
        handlers: FeedHandlers,
        meta: FeedMeta,
        client: Arc<Client>,
    ) -> Self {
        Self {
            lua,
            handlers,
            meta,
            client,
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
    ) -> Result<Page<T, Value>> {
        let http_request: HttpRequest = self.call_function(&pair.request, args)?;
        let http_response = self.execute_http(&http_request).await?;
        let lua_response = self.lua.to_value(&http_response)?;
        let page: Page<T, Value> = pair.parse.call(lua_response)?;
        Ok(page)
    }

    /// Execute a full request/parse cycle for paginated results, with
    /// exponential-backoff retry on transient errors.
    ///
    /// Retries up to [`MAX_RETRIES`] times.  Non-retryable errors are returned
    /// immediately without retrying.
    async fn execute_paged_cycle_with_retry<T: DeserializeOwned>(
        &self,
        pair: &HandlerPair,
        keyword: &str,
        cursor: &Value,
    ) -> Result<Page<T, Value>> {
        let mut attempt = 0u32;
        loop {
            let args = (keyword, cursor.clone());
            match self.execute_paged_cycle(pair, args).await {
                Ok(page) => return Ok(page),
                Err(err) if attempt < MAX_RETRIES && err.is_retryable() => {
                    let delay_ms = BASE_DELAY_MS * BACKOFF_MULTIPLIER.pow(attempt);
                    sleep(Duration::from_millis(delay_ms)).await;
                    attempt += 1;
                }
                Err(err) => return Err(err),
            }
        }
    }

    /// Execute a full request/parse cycle for non-paginated results.
    async fn execute_cycle<T: DeserializeOwned>(
        &self,
        pair: &HandlerPair,
        args: impl mlua::IntoLuaMulti,
    ) -> Result<T> {
        let http_request: HttpRequest = self.call_function(&pair.request, args)?;
        let http_response = self.execute_http(&http_request).await?;
        let lua_response = self.lua.to_value(&http_response)?;
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
    /// `key` is the primary argument passed to the Lua `request` function
    /// (e.g. a search keyword or a book ID).  The cursor starts as `Nil` and
    /// is updated from each page's `next_cursor` field.
    ///
    /// Each page fetch is retried with exponential backoff on transient errors.
    /// A permanent error terminates the stream immediately.
    fn paged_stream<'a, T>(&'a self, pair: &'a HandlerPair, key: &'a str) -> FeedStream<'a, T>
    where
        T: DeserializeOwned + Send + 'a,
    {
        Box::pin(stream! {
            let mut cursor = Value::Nil;
            loop {
                match self.execute_paged_cycle_with_retry(pair, key, &cursor).await {
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

    // -----------------------------------------------------------------------
    // HTTP execution
    // -----------------------------------------------------------------------

    /// Execute an HTTP request described by an [`HttpRequest`] and return an
    /// [`HttpResponse`].
    async fn execute_http(&self, req: &HttpRequest) -> Result<HttpResponse> {
        let method = req.method.parse().unwrap_or(reqwest::Method::GET);
        let mut builder = self.client.request(method, &req.url);

        if let Some(params) = &req.params {
            builder = builder.query(params);
        }

        if let Some(headers) = &req.headers {
            for (key, value) in headers {
                builder = builder.header(key.as_str(), value.as_str());
            }
        }

        if let Some(body) = &req.body {
            builder = builder.body(body.clone());
        }

        let response = builder.send().await?;

        let status = response.status().as_u16();
        let url = response.url().to_string();

        let headers: HashMap<String, String> = response
            .headers()
            .iter()
            .filter_map(|(k, v)| {
                v.to_str()
                    .ok()
                    .map(|val| (k.as_str().to_owned(), val.to_owned()))
            })
            .collect();

        let body = response.text().await?;

        Ok(HttpResponse {
            status,
            headers,
            body,
            url,
        })
    }
}

// ---------------------------------------------------------------------------
// Feed trait implementation
// ---------------------------------------------------------------------------

impl Feed for LuaFeed {
    fn search<'a>(&'a self, keyword: &'a str) -> FeedStream<'a, SearchResult> {
        self.paged_stream(&self.handlers.search, keyword)
    }

    async fn book_info(&self, id: &str) -> Result<BookInfo> {
        self.execute_cycle(&self.handlers.book_info, id).await
    }

    fn chapters<'a>(&'a self, book_id: &'a str) -> FeedStream<'a, ChapterInfo> {
        self.paged_stream(&self.handlers.chapters, book_id)
    }

    fn chapter_content<'a>(&'a self, chapter_id: &'a str) -> FeedStream<'a, ChapterContent> {
        self.paged_stream(&self.handlers.chapter_content, chapter_id)
    }

    fn meta(&self) -> &FeedMeta {
        &self.meta
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use tokio_stream::StreamExt as _;

    use super::*;
    use crate::error::Error;
    use crate::script::engine::ScriptEngine;

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
    chapter_content = {
        request = function(chapter_id, cursor) return { url = meta.base_url .. "/content/" .. chapter_id } end,
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
    chapter_content = {
        request = function(chapter_id, cursor) return { url = meta.base_url .. "/content/" .. chapter_id } end,
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
        use crate::script::engine::ScriptEngine;
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
    chapter_content = {{ request = function(id, c) return {{ url = meta.base_url }} end, parse = function(r) return {{ items = {{}}, next_cursor = nil }} end }},
}}
"#,
            make_header(&server.url())
        );

        let feed = ScriptEngine::new()
            .load_feed(&script)
            .await
            .expect("load");

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
        // mockito matches `path_and_query` (path + query string together),
        // so we use a Regex that accepts `/search` with any query params.
        let _mock = server
            .mock("GET", mockito::Matcher::Regex(r"^/search(\?.*)?$".into()))
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(
                r#"{"items":[{"id":"1","title":"Rust Book","author":"Steve"},{"id":"2","title":"Async Rust","author":"Alice"}],"next_cursor":null}"#,
            )
            .create_async()
            .await;

        let feed = load_feed(&server.url(), SEARCH_BODY).await;
        let results: Vec<_> = feed
            .search("rust")
            .collect::<Vec<_>>()
            .await;

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
            matches!(results[0], Err(Error::Lua(_))),
            "expected Lua error, got: {:?}",
            results[0]
        );
    }
}

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

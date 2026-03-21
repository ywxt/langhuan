use std::collections::HashMap;
use std::sync::Arc;

use mlua::{FromLua, Lua, LuaSerdeExt, Value};
use reqwest::Client;
use serde::de::DeserializeOwned;

use crate::error::Result;
use crate::feed::Feed;
use crate::model::{
    BookInfo, ChapterContent, ChapterInfo, HttpRequest, HttpResponse, Page, SearchResult,
};
use crate::script::meta::FeedMeta;

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
        // 1. Call request function → HttpRequest.
        let http_request: HttpRequest = self.call_function(&pair.request, args)?;

        // 2. Execute HTTP.
        let http_response = self.execute_http(&http_request).await?;

        // 3. Call parse function → Page<T, Value> via FromLua.
        let lua_response = self.lua.to_value(&http_response)?;
        let page: Page<T, Value> = pair.parse.call(lua_response)?;

        Ok(page)
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
    type Cursor = Value;

    async fn search(
        &self,
        keyword: &str,
        cursor: Option<&Self::Cursor>,
    ) -> Result<Page<SearchResult, Value>> {
        let lua_cursor = cursor.unwrap_or(&Value::Nil);
        let args = (keyword, lua_cursor);
        self.execute_paged_cycle(&self.handlers.search, args).await
    }

    async fn book_info(&self, id: &str) -> Result<BookInfo> {
        self.execute_cycle(&self.handlers.book_info, id).await
    }

    async fn chapters(
        &self,
        book_id: &str,
        cursor: Option<&Self::Cursor>,
    ) -> Result<Page<ChapterInfo, Value>> {
        let lua_cursor = cursor.unwrap_or(&Value::Nil);
        let args = (book_id, lua_cursor);
        self.execute_paged_cycle(&self.handlers.chapters, args)
            .await
    }

    async fn chapter_content(
        &self,
        chapter_id: &str,
        cursor: Option<&Self::Cursor>,
    ) -> Result<Page<ChapterContent, Value>> {
        let lua_cursor = cursor.unwrap_or(&Value::Nil);
        let args = (chapter_id, lua_cursor);
        self.execute_paged_cycle(&self.handlers.chapter_content, args)
            .await
    }

    fn meta(&self) -> &FeedMeta {
        &self.meta
    }
}

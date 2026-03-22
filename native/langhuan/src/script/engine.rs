use std::sync::Arc;

use mlua::{Lua, LuaSerdeExt, StdLib};
use reqwest::Client;

use crate::error::Result;
use crate::script::modules;
use crate::script::lua_feed::{FeedHandlers, LuaFeed};
use crate::script::meta::{self, FeedMeta};

/// The script engine manages Lua VM creation and HTTP client sharing.
///
/// Create one `ScriptEngine` and use it to load multiple feed scripts. Each
/// loaded feed gets its own sandboxed Lua VM but shares the same HTTP client.
#[derive(Clone)]
pub struct ScriptEngine {
    client: Arc<Client>,
}

impl ScriptEngine {
    /// Create a new script engine with a default HTTP client.
    pub fn new() -> Self {
        Self {
            client: Arc::new(Client::new()),
        }
    }

    /// Create a new script engine with a custom HTTP client.
    pub fn with_client(client: Client) -> Self {
        Self {
            client: Arc::new(client),
        }
    }

    /// Load a Lua feed script and return a [`LuaFeed`].
    ///
    /// This will:
    /// 1. Parse the `==Feed==` metadata header.
    /// 2. Create a sandboxed Lua VM (only safe standard libraries).
    /// 3. Inject a `meta` table (all header fields) as a Lua global.
    /// 4. Execute the script body and capture the returned handler table.
    ///
    /// The script body is executed with [`mlua`]'s async eval, allowing Lua
    /// coroutines to yield during initialisation without blocking the runtime.
    pub async fn load_feed(&self, script: &str) -> Result<LuaFeed> {
        // 1. Parse metadata header.
        let (feed_meta, body_offset) = meta::parse_meta(script)?;
        let script_body = &script[body_offset..];

        // 2. Create sandboxed Lua VM.
        let lua = create_sandbox_lua()?;

        // 3. Inject globals from metadata.
        inject_globals(&lua, &feed_meta)?;

        // 4. Execute the script body — must return a table.
        let handlers: FeedHandlers = lua.load(script_body).eval_async().await?;

        Ok(LuaFeed::new(
            lua,
            handlers,
            feed_meta,
            // Client is Arc-backed internally; clone is cheap.
            (*self.client).clone(),
        ))
    }
}

impl Default for ScriptEngine {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Create a Lua VM with only safe standard libraries.
///
/// Enabled: `string`, `table`, `math`, `utf8`, `coroutine`, `base` (print, etc.)
/// Disabled: `os`, `io`, `debug`, `package`, `ffi`
fn create_sandbox_lua() -> Result<Lua> {
    let safe_libs =
        StdLib::STRING | StdLib::TABLE | StdLib::MATH | StdLib::UTF8 | StdLib::COROUTINE;

    let lua = Lua::new_with(safe_libs, mlua::LuaOptions::default())?;
    modules::register_builtin_modules(&lua)?;
    Ok(lua)
}

/// Inject metadata-derived globals into the Lua VM.
///
/// Serialises the entire [`FeedMeta`] into a Lua `meta` table so that
/// scripts can reference e.g. `meta.base_url`, `meta.charset`, etc.
fn inject_globals(lua: &Lua, meta: &FeedMeta) -> Result<()> {
    let meta_value = lua.to_value(meta)?;
    lua.globals().set("meta", meta_value)?;
    Ok(())
}

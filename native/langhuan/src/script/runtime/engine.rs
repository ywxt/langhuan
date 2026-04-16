use std::sync::Arc;
use std::time::{Duration, Instant};

use mlua::{HookTriggers, Lua, LuaSerdeExt, StdLib, VmState};
use reqwest::Client;

use crate::error::Result;
use crate::feed::FeedMeta;
use crate::script::lua::feed::{FeedHandlers, LuaFeed};
use crate::script::meta;
use crate::script::runtime::modules;

/// Maximum execution time for a single Lua call before it is interrupted.
const SCRIPT_TIMEOUT: Duration = Duration::from_secs(30);

// Memory limit for Lua VMs: 10 MiB (in bytes).
const MEMORY_LIMIT: usize = 10 * 1024 * 1024;

/// Call a Lua function with a per-call execution timeout.
///
/// Sets an instruction-counting hook before the call that checks elapsed time.
/// The hook is removed after the call completes (or errors). This gives each
/// call an independent `SCRIPT_TIMEOUT` window.
pub(crate) fn timed_call<R: mlua::FromLuaMulti>(
    lua: &Lua,
    func: &mlua::Function,
    args: impl mlua::IntoLuaMulti,
) -> mlua::Result<R> {
    timed_call_with_timeout(lua, func, args, SCRIPT_TIMEOUT)
}

fn timed_call_with_timeout<R: mlua::FromLuaMulti>(
    lua: &Lua,
    func: &mlua::Function,
    args: impl mlua::IntoLuaMulti,
    timeout: Duration,
) -> mlua::Result<R> {
    let start = Instant::now();
    lua.set_hook(
        HookTriggers::new().every_nth_instruction(4096),
        move |_lua, _debug| {
            if start.elapsed() > timeout {
                Err(mlua::Error::RuntimeError(
                    "script execution timed out".into(),
                ))
            } else {
                Ok(VmState::Continue)
            }
        },
    )?;
    let result = func.call(args);
    lua.remove_hook();
    result
}

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

        // 1b. Reject feeds whose schema version is newer than we support.
        if feed_meta.schema_version > crate::feed::meta::FEED_SCHEMA_VERSION {
            return Err(crate::error::Error::feed_schema_too_new(
                feed_meta.id.clone(),
                feed_meta.schema_version,
                crate::feed::meta::FEED_SCHEMA_VERSION,
            ));
        }

        tracing::info!(
            feed_id = %feed_meta.id,
            feed_version = %feed_meta.version,
            "loading Lua feed script"
        );
        let script_body = &script[body_offset..];

        // 2. Create sandboxed Lua VM.
        let lua = create_sandbox_lua()?;

        // 3. Inject globals from metadata.
        inject_globals(&lua, &feed_meta)?;

        // 4. Execute the script body — must return a table.
        let handlers: FeedHandlers = lua.load(script_body).eval_async().await?;

        tracing::debug!(
            feed_id = %feed_meta.id,
            "Lua feed handlers loaded"
        );

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
/// Enabled: `string`, `table`, `math`, `utf8`, `coroutine`
/// Partially enabled: `os` (only date/time functions)
/// Disabled: `io`, `debug`, `package`, `ffi`, `base` (load, dofile, etc.)
fn create_sandbox_lua() -> Result<Lua> {
    let safe_libs = StdLib::STRING
        | StdLib::TABLE
        | StdLib::MATH
        | StdLib::UTF8
        | StdLib::COROUTINE
        | StdLib::OS;

    let lua = Lua::new_with(safe_libs, mlua::LuaOptions::default())?;
    
    lua.set_memory_limit(MEMORY_LIMIT)?;

    // -- Restrict `base` library functions that can execute code or access the filesystem ---
    {
        let globals = lua.globals();
        for key in &["load", "loadfile", "dofile", "loadstring"] {
            globals.set(*key, mlua::Value::Nil)?;
        }
    }

    // -- Restrict `os` to date/time only --------------------------------
    {
        let os: mlua::Table = lua.globals().get("os")?;
        for key in &[
            "execute",
            "exit",
            "getenv",
            "remove",
            "rename",
            "tmpname",
            "setlocale",
        ] {
            os.set(*key, mlua::Value::Nil)?;
        }
    }

    modules::register_builtin_modules(&lua)?;
    Ok(lua)
}

/// Inject metadata-derived globals into the Lua VM.
///
/// Serialises the entire [`FeedMeta`] into a Lua `meta` table so that
/// scripts can reference e.g. `meta.base_url`, `meta.charset`, etc.
fn inject_globals(lua: &Lua, meta: &FeedMeta) -> Result<()> {
    let meta_value = lua.to_value_with(meta, crate::script::LUA_SERIALIZE_OPTIONS)?;
    lua.globals().set("meta", meta_value)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn test_sandbox_without_load_function() {
        let lua = create_sandbox_lua().expect("failed to create sandbox Lua VM");
        let code = r#"
            assert(load == nil, "load should be disabled in sandbox");
            assert(dofile == nil, "dofile should be disabled in sandbox");
            assert(loadfile == nil, "loadfile should be disabled in sandbox");
            assert(loadstring == nil, "loadstring should be disabled in sandbox");
        "#;
        let _: () = lua.load(code).eval().unwrap();
    }

    #[test]
    fn test_sandbox_os_library() {
        let lua = create_sandbox_lua().expect("failed to create sandbox Lua VM");
        let code = r#"
            assert(os.execute == nil, "os.execute should be disabled in sandbox");
            assert(os.getenv == nil, "os.getenv should be disabled in sandbox");
            assert(os.date ~= nil, "os.date should be available in sandbox");
            assert(os.time ~= nil, "os.time should be available in sandbox");
            assert(os.difftime ~= nil, "os.difftime should be available in sandbox");
            assert(os.setlocale == nil, "os.setlocale should be disabled in sandbox");
            assert(os.tmpname == nil, "os.tmpname should be disabled in sandbox");
            assert(os.remove == nil, "os.remove should be disabled in sandbox");
            assert(os.rename == nil, "os.rename should be disabled in sandbox");
        "#;
        let _: () = lua.load(code).eval().unwrap();
    }

    #[test]
    fn test_infinite_loop_is_interrupted() {
        let lua = create_sandbox_lua().expect("failed to create sandbox Lua VM");
        let func = lua
            .load("while true do end")
            .into_function()
            .expect("compile chunk");

        let err = timed_call_with_timeout::<()>(&lua, &func, (), Duration::from_millis(100))
            .expect_err("infinite loop should be interrupted");

        let msg = err.to_string();
        assert!(
            msg.contains("timed out"),
            "unexpected error: {msg}"
        );
    }
}

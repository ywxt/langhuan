//! Built-in Lua modules available via `require("@langhuan/<name>")`.
//!
//! # Architecture
//! Each sub-module exposes a single function:
//! ```text
//! pub fn module(lua: &Lua) -> mlua::Result<mlua::Value>
//! ```
//! It constructs and returns the module value (typically a Lua table) but does
//! **not** register it anywhere.  Registration is handled centrally by
//! [`register_builtin_modules`], which stores every module in the Lua registry
//! and installs a custom `require` function that looks them up.
//!
//! # Usage in Lua scripts
//! ```lua
//! local json = require("@langhuan/json")
//! local data = json.decode('{"key": "value"}')
//! local str  = json.encode({ key = "value" })
//! ```

mod json;

use mlua::{Lua, Result, Value};

/// A module factory: given a [`Lua`] context, produce the module value.
type ModuleFactory = fn(&Lua) -> Result<Value>;

/// All built-in `@langhuan/*` modules.
///
/// Each entry is `(require_name, factory)`. The `require_name` must start
/// with `@langhuan/` and is the exact string callers pass to `require(...)`.
const BUILTIN_MODULES: &[(&str, ModuleFactory)] = &[("@langhuan/json", json::module)];

/// Register all built-in modules and install the custom `require` function.
///
/// Must be called once after the sandboxed [`Lua`] VM is created.
/// Stores each module in the Lua registry under a key derived from its name,
/// then overrides the global `require` to look up those registry entries.
pub fn register_builtin_modules(lua: &Lua) -> Result<()> {
    for (name, factory) in BUILTIN_MODULES {
        let value = factory(lua)?;
        lua.set_named_registry_value(&registry_key(name), value)?;
    }

    // Install the custom `require` that resolves @langhuan/* names.
    let require_fn = lua.create_function(|lua, name: String| {
        let key = registry_key(&name);
        match lua.named_registry_value::<Value>(&key)? {
            Value::Nil => Err(mlua::Error::RuntimeError(format!(
                "module not found: '{name}'. \
                 Only @langhuan/* built-in modules are supported.",
            ))),
            value => Ok(value),
        }
    })?;

    lua.globals().set("require", require_fn)?;
    Ok(())
}

/// Derive the Lua registry key for a module name.
///
/// E.g. `"@langhuan/json"` → `"__langhuan_module_@langhuan/json"`.
fn registry_key(name: &str) -> String {
    format!("__langhuan_module_{name}")
}

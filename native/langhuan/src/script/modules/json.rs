//! `@langhuan/json` — JSON encode/decode for Lua scripts.
//!
//! Exposes two functions via the returned module table:
//! - `json.decode(str)   -> value` — Parse a JSON string into a Lua value.
//! - `json.encode(value) -> string` — Serialize a Lua value to a JSON string.

use mlua::{Lua, LuaSerdeExt as _, Result, Value};

/// Build and return the `@langhuan/json` module table.
///
/// Called by [`super::register_builtin_modules`]; does not register anything
/// itself — registration is the caller's responsibility.
pub fn module(lua: &Lua) -> Result<Value> {
    let decode = lua.create_function(|lua, s: String| {
        let v: serde_json::Value = serde_json::from_str(&s)
            .map_err(|e| mlua::Error::RuntimeError(format!("json.decode: {e}")))?;
        // `serialize_none_to_null(false)` converts Rust `None` → Lua `nil`.
        // `serialize_unit_to_null(false)` converts `serde_json::Value::Null`
        // → Lua `nil` (JSON null serializes as a unit variant, not as None).
        // Together these ensure JSON `null` becomes Lua `nil` rather than the
        // null-userdata sentinel, so `is_nil()` checks work correctly.
        lua.to_value_with(
            &v,
            mlua::SerializeOptions::new()
                .serialize_none_to_null(false)
                .serialize_unit_to_null(false),
        )
    })?;

    let encode = lua.create_function(|lua, v: Value| {
        let sv: serde_json::Value = lua
            .from_value(v)
            .map_err(|e| mlua::Error::RuntimeError(format!("json.encode: {e}")))?;
        serde_json::to_string(&sv)
            .map_err(|e| mlua::Error::RuntimeError(format!("json.encode: {e}")))
    })?;

    let table = lua.create_table()?;
    table.set("decode", decode)?;
    table.set("encode", encode)?;

    Ok(Value::Table(table))
}

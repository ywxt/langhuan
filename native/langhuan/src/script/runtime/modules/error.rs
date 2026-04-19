//! `@langhuan/error` — structured error raising for Lua feed scripts.
//!
//! Provides `raise(code, message)` and convenience methods for each predefined
//! error code. All methods raise a Lua error with a special prefix that Rust
//! intercepts in `From<mlua::Error> for Error`.

use mlua::{Lua, Result, Value};

use crate::error::EXPECTED_ERROR_PREFIX;

fn raise_expected(code: &str, message: &str) -> mlua::Error {
    mlua::Error::RuntimeError(format!("{EXPECTED_ERROR_PREFIX}{code}:{message}"))
}

pub fn module(lua: &Lua) -> Result<Value> {
    let raise = lua.create_function(|_, (code, message): (String, String)| {
        Err::<Value, _>(raise_expected(&code, &message))
    })?;

    let auth_required = lua.create_function(|_, message: String| {
        Err::<Value, _>(raise_expected("auth_required", &message))
    })?;

    let cf_challenge = lua.create_function(|_, message: String| {
        Err::<Value, _>(raise_expected("cf_challenge", &message))
    })?;

    let rate_limited = lua.create_function(|_, message: String| {
        Err::<Value, _>(raise_expected("rate_limited", &message))
    })?;

    let content_not_found = lua.create_function(|_, message: String| {
        Err::<Value, _>(raise_expected("content_not_found", &message))
    })?;

    let source_unavailable = lua.create_function(|_, message: String| {
        Err::<Value, _>(raise_expected("source_unavailable", &message))
    })?;

    let table = lua.create_table()?;
    table.set("raise", raise)?;
    table.set("auth_required", auth_required)?;
    table.set("cf_challenge", cf_challenge)?;
    table.set("rate_limited", rate_limited)?;
    table.set("content_not_found", content_not_found)?;
    table.set("source_unavailable", source_unavailable)?;

    Ok(Value::Table(table))
}

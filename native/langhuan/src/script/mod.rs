pub mod lua;
pub mod meta;
pub mod runtime;
pub mod source;

const LUA_SERIALIZE_OPTIONS: mlua::serde::SerializeOptions = mlua::serde::SerializeOptions::new()
    .serialize_none_to_null(false)
    .serialize_unit_to_null(false)
    .detect_serde_json_arbitrary_precision(true);

//! Structured value bridge between Rust and the sandboxed QuickJS realms.
//!
//! The reducer call boundary used to round-trip every argument and result
//! through JSON (`serde → string → json_parse → call → json_stringify →
//! serde`), which silently dropped `undefined`, mangled typed arrays, threw
//! on BigInt, and capped every result by stringified size. This module
//! replaces that boundary with direct value construction and typed readers:
//!
//! * JSON-shaped host data (operation, input, cursor, auth) is built into
//!   live JavaScript objects.
//! * `next_state` and `compute` results are carried as opaque
//!   [`OpaqueJsValue`] persistents — JavaScript to JavaScript, byte
//!   faithful, no serialization.
//! * Step results are extracted with strict per-field readers so error
//!   messages name the offending field.
//! * [`JsData`] is the realm-independent materialization used to copy the
//!   compute input and result across the disposable compute realm; unlike
//!   JSON it preserves `undefined` and raw bytes.

use std::collections::HashMap;

use bytes::Bytes;
use rquickjs::{Array, Ctx, Function, Object, Persistent, TypedArray, Value as JsValue};
use serde_json::Value;

use super::sandbox::resolve_owner;
use crate::error::{Error, Result};
use crate::feed::{AuthPageContext, CookieEntry, WebviewSnapshot};
use crate::http::{HttpBody, HttpRequest, HttpResponse};

/// Upper bound for values materialized across the bridge, matching the
/// serialized-result limit the old JSON boundary enforced.
pub(super) const MAX_BRIDGE_BYTES: usize = 16 * 1024 * 1024;

/// A persistent JavaScript value carried across `.await` points between
/// reducer rounds.
///
/// QuickJS persistents are not `Send`. This wrapper moves them the same way
/// [`JsObject`](super::sandbox::JsObject) moves its realm state: the wrapped
/// value is only restored or saved while the realm mutex is held, so no two
/// threads ever touch the same context through it.
pub(super) struct OpaqueJsValue(Persistent<JsValue<'static>>);

// SAFETY: the persistent is only restored inside `JsObject::with_realm`,
// which serializes all context access behind one mutex. Moving the wrapper
// between threads never touches the QuickJS heap.
unsafe impl Send for OpaqueJsValue {}

impl OpaqueJsValue {
    pub(super) fn save<'js>(ctx: &Ctx<'js>, value: JsValue<'js>) -> Self {
        Self(Persistent::save(ctx, value))
    }

    fn restore<'js>(&self, ctx: &Ctx<'js>) -> rquickjs::Result<JsValue<'js>> {
        self.0.clone().restore(ctx)
    }
}

/// Resolve a method path on the feed object and fetch it as a function.
pub(super) fn resolve_method<'js>(
    feed_object: &Object<'js>,
    path: &[&str],
) -> rquickjs::Result<(Object<'js>, Function<'js>)> {
    let (owner, name) = resolve_owner(feed_object.clone(), path)?.ok_or_else(|| {
        rquickjs::Error::new_from_js_message(
            "object",
            "function",
            format!("missing JavaScript method: {}", path.join(".")),
        )
    })?;
    let function: Function = owner.get(name.as_str())?;
    Ok((owner, function))
}

/// Call a resolved method with `this` bound to its owner.
pub(super) fn call_method<'js>(
    ctx: &Ctx<'js>,
    owner: &Object<'js>,
    function: &Function<'js>,
    arguments: &[JsValue<'js>],
) -> rquickjs::Result<JsValue<'js>> {
    let mut call_arguments = rquickjs::function::Args::new(ctx.clone(), arguments.len());
    call_arguments.this(owner.clone())?;
    for argument in arguments {
        call_arguments.push_arg(argument.clone())?;
    }
    function.call_arg(call_arguments)
}

// ---------------------------------------------------------------------------
// JsData: realm-independent materialization
// ---------------------------------------------------------------------------

/// A deep-copied, realm-independent JavaScript value.
///
/// Used where a value must cross between the feed realm and the disposable
/// compute realm (compute input and results). Unlike JSON it preserves
/// `undefined` and raw bytes; functions and symbols are rejected because
/// they cannot be copied.
#[derive(Debug, Clone, PartialEq)]
pub(super) enum JsData {
    Undefined,
    Null,
    Bool(bool),
    Int(i32),
    Num(f64),
    Str(String),
    Bytes(Bytes),
    Arr(Vec<JsData>),
    Obj(Vec<(String, JsData)>),
}

impl JsData {
    /// Materialize JSON-shaped host data (operation input, cursor, auth).
    pub(super) fn from_json(value: &Value) -> Self {
        match value {
            Value::Null => Self::Null,
            Value::Bool(flag) => Self::Bool(*flag),
            Value::Number(number) => {
                if let Some(int) = number.as_i64() {
                    i32::try_from(int).map(Self::Int).unwrap_or_else(|_| Self::Num(int as f64))
                } else if let Some(uint) = number.as_u64() {
                    Self::Num(uint as f64)
                } else {
                    Self::Num(number.as_f64().unwrap_or(f64::NAN))
                }
            }
            Value::String(text) => Self::Str(text.clone()),
            Value::Array(items) => Self::Arr(items.iter().map(Self::from_json).collect()),
            Value::Object(entries) => Self::Obj(
                entries
                    .iter()
                    .map(|(key, value)| (key.clone(), Self::from_json(value)))
                    .collect(),
            ),
        }
    }

    /// Render back to JSON (test helpers and diagnostics).
    #[cfg(test)]
    pub(super) fn into_json(self) -> Value {
        match self {
            Self::Undefined | Self::Null => Value::Null,
            Self::Bool(flag) => Value::Bool(flag),
            Self::Int(int) => Value::Number(serde_json::Number::from(i64::from(int))),
            Self::Num(number) => {
                serde_json::Number::from_f64(number).map_or(Value::Null, Value::Number)
            }
            Self::Str(text) => Value::String(text),
            Self::Bytes(_) => Value::Null,
            Self::Arr(items) => Value::Array(items.into_iter().map(Self::into_json).collect()),
            Self::Obj(entries) => Value::Object(
                entries
                    .into_iter()
                    .map(|(key, value)| (key, Self::into_json(value)))
                    .collect(),
            ),
        }
    }

    /// Approximate materialized size, used to keep bridge payloads bounded.
    pub(super) fn measure(&self) -> usize {
        match self {
            Self::Undefined | Self::Null | Self::Bool(_) => 8,
            Self::Int(_) | Self::Num(_) => 16,
            Self::Str(text) => text.len(),
            Self::Bytes(bytes) => bytes.len(),
            Self::Arr(items) => {
                items.len() + items.iter().map(Self::measure).sum::<usize>()
            }
            Self::Obj(entries) => entries
                .iter()
                .map(|(key, value)| key.len() + 8 + value.measure())
                .sum(),
        }
    }
}

/// Build a live JavaScript value from [`JsData`].
pub(super) fn jsdata_to_js<'js>(
    ctx: &Ctx<'js>,
    data: &JsData,
) -> rquickjs::Result<JsValue<'js>> {
    let value = match data {
        JsData::Undefined => JsValue::new_undefined(ctx.clone()),
        JsData::Null => JsValue::new_null(ctx.clone()),
        JsData::Bool(flag) => JsValue::new_bool(ctx.clone(), *flag),
        JsData::Int(int) => JsValue::new_int(ctx.clone(), *int),
        JsData::Num(number) => JsValue::new_float(ctx.clone(), *number),
        JsData::Str(text) => rquickjs::String::from_str(ctx.clone(), text)?.into_value(),
        JsData::Bytes(bytes) => bytes_to_u8array(ctx, bytes)?,
        JsData::Arr(items) => {
            let array = Array::new(ctx.clone())?;
            for (index, item) in items.iter().enumerate() {
                array.set(index, jsdata_to_js(ctx, item)?)?;
            }
            array.into_value()
        }
        JsData::Obj(entries) => {
            let object = Object::new(ctx.clone())?;
            for (key, value) in entries {
                object.set(key.as_str(), jsdata_to_js(ctx, value)?)?;
            }
            object.into_value()
        }
    };
    Ok(value)
}

/// Materialize a live JavaScript value as [`JsData`].
///
/// Rejects functions, symbols, and BigInt because they cannot be copied
/// across realms. Function-valued object properties are skipped, matching
/// how `JSON.stringify` drops them.
pub(super) fn js_to_jsdata(value: &JsValue<'_>) -> Result<JsData> {
    let data = js_to_jsdata_inner(value)?;
    if data.measure() > MAX_BRIDGE_BYTES {
        return Err(Error::javascript("JavaScript value exceeds the size limit"));
    }
    Ok(data)
}

fn js_to_jsdata_inner(value: &JsValue<'_>) -> Result<JsData> {
    if value.is_undefined() {
        return Ok(JsData::Undefined);
    }
    if value.is_null() {
        return Ok(JsData::Null);
    }
    if value.is_bool() {
        return Ok(JsData::Bool(value.as_bool().unwrap_or(false)));
    }
    if value.is_int() {
        return Ok(JsData::Int(value.as_int().unwrap_or(0)));
    }
    if value.is_float() {
        return Ok(JsData::Num(value.as_float().unwrap_or(f64::NAN)));
    }
    if value.is_string() {
        let text = value
            .get::<String>()
            .map_err(|_| Error::javascript("a string value could not be read"))?;
        return Ok(JsData::Str(text));
    }
    if value.is_big_int() {
        return Err(Error::javascript(
            "BigInt values are not supported; convert them with String() first",
        ));
    }
    if let Some(bytes) = u8_to_bytes(value) {
        return Ok(JsData::Bytes(bytes));
    }
    if value.is_array() {
        let array = value.clone().into_array().ok_or_else(|| {
            Error::javascript("an array value could not be materialized")
        })?;
        let mut items = Vec::with_capacity(array.len());
        for element in array.iter::<JsValue>() {
            let element = element
                .map_err(|error| Error::javascript(format!("array iteration failed: {error}")))?;
            items.push(js_to_jsdata_inner(&element)?);
        }
        return Ok(JsData::Arr(items));
    }
    if value.is_function() {
        return Err(Error::javascript(
            "functions cannot be copied across realms",
        ));
    }
    if let Some(object) = value.clone().into_object() {
        let mut entries = Vec::new();
        for entry in object.props::<String, JsValue>() {
            let (key, prop) = entry.map_err(|error| {
                Error::javascript(format!("object iteration failed: {error}"))
            })?;
            // Function-valued properties are dropped, like JSON.stringify.
            if prop.is_function() {
                continue;
            }
            entries.push((key, js_to_jsdata_inner(&prop)?));
        }
        return Ok(JsData::Obj(entries));
    }
    Err(Error::javascript(
        "symbols cannot be copied across realms",
    ))
}

// ---------------------------------------------------------------------------
// Byte helpers
// ---------------------------------------------------------------------------

/// Copy the bytes of a `Uint8Array` value.
fn u8_to_bytes(value: &JsValue<'_>) -> Option<Bytes> {
    let typed = TypedArray::<u8>::from_value(value.clone()).ok()?;
    // SAFETY: no JavaScript runs while the slice is borrowed; the bytes are
    // copied immediately.
    let slice = unsafe { typed.as_bytes()? };
    Some(Bytes::copy_from_slice(slice))
}

/// Create a `Uint8Array` value from raw bytes.
pub(super) fn bytes_to_u8array<'js>(
    ctx: &Ctx<'js>,
    bytes: &[u8],
) -> rquickjs::Result<JsValue<'js>> {
    Ok(TypedArray::<u8>::new_copy(ctx.clone(), bytes)?.into_value())
}

// ---------------------------------------------------------------------------
// JSON conversion
// ---------------------------------------------------------------------------

/// Convert a JavaScript value to JSON the way `JSON.stringify` would:
/// `undefined` and functions are dropped (or rendered `null` inside arrays),
/// objects with a `toJSON` method are converted through it, and non-finite
/// numbers become `null`.
///
/// Returns `None` when the value would be dropped entirely. Typed arrays are
/// rejected with guidance instead of being mangled.
pub(super) fn js_to_json<'js>(ctx: &Ctx<'js>, value: &JsValue<'js>) -> Result<Option<Value>> {
    if value.is_function() {
        return Err(Error::javascript(
            "functions cannot be returned to the host; return plain data instead",
        ));
    }
    if value.is_symbol() {
        return Err(Error::javascript(
            "symbols cannot be returned to the host",
        ));
    }
    let mut size = 0usize;
    convert_to_json(ctx, value, &mut size)
}

fn convert_to_json<'js>(
    ctx: &Ctx<'js>,
    value: &JsValue<'js>,
    size: &mut usize,
) -> Result<Option<Value>> {
    if value.is_undefined() {
        return Ok(None);
    }
    if value.is_null() {
        return Ok(Some(Value::Null));
    }
    if value.is_bool() {
        bump_json_size(size, 5)?;
        return Ok(Some(Value::Bool(value.as_bool().unwrap_or(false))));
    }
    if value.is_int() {
        bump_json_size(size, 8)?;
        let int = value.as_int().unwrap_or(0);
        return Ok(Some(Value::Number(serde_json::Number::from(i64::from(int)))));
    }
    if value.is_float() {
        bump_json_size(size, 8)?;
        let number = value.as_float().unwrap_or(f64::NAN);
        // JSON renders non-finite numbers as null.
        return Ok(Some(
            serde_json::Number::from_f64(number).map_or(Value::Null, Value::Number),
        ));
    }
    if value.is_string() {
        let text = value
            .get::<String>()
            .map_err(|_| Error::javascript("a string value could not be read"))?;
        bump_json_size(size, text.len())?;
        return Ok(Some(Value::String(text)));
    }
    if value.is_big_int() {
        return Err(Error::javascript(
            "BigInt values cannot be converted to JSON; use .toString() first",
        ));
    }
    if u8_to_bytes(value).is_some() {
        return Err(Error::javascript(
            "Uint8Array values cannot be returned to the host; decode them with \
             TextDecoder or encode them with Bytes.toBase64/Bytes.toHex first",
        ));
    }
    if value.is_array() {
        let array = value
            .clone()
            .into_array()
            .ok_or_else(|| Error::javascript("an array value could not be read"))?;
        let mut items = Vec::with_capacity(array.len());
        for element in array.iter::<JsValue>() {
            let element = element
                .map_err(|error| Error::javascript(format!("array iteration failed: {error}")))?;
            // Undefined slots and functions become null, like JSON.stringify.
            let converted = convert_to_json(ctx, &element, size)?.unwrap_or(Value::Null);
            bump_json_size(size, 1)?;
            items.push(converted);
        }
        return Ok(Some(Value::Array(items)));
    }
    if let Some(object) = value.clone().into_object() {
        // Honor toJSON like JSON.stringify does (this covers Date).
        if let Ok(to_json) = object.get::<_, Function>("toJSON") {
            let mut arguments = rquickjs::function::Args::new(ctx.clone(), 0);
            arguments
                .this(object.clone())
                .map_err(js_call_error)?;
            let converted = to_json.call_arg(arguments).map_err(js_call_error)?;
            return convert_to_json(ctx, &converted, size);
        }
        let mut entries = Vec::new();
        for entry in object.props::<String, JsValue>() {
            let (key, prop) = entry
                .map_err(|error| Error::javascript(format!("object iteration failed: {error}")))?;
            // Function-valued properties are dropped, like JSON.stringify.
            if let Some(converted) = convert_to_json(ctx, &prop, size)? {
                bump_json_size(size, key.len() + 16)?;
                entries.push((key, converted));
            }
        }
        return Ok(Some(Value::Object(entries.into_iter().collect())));
    }
    Ok(None)
}

fn bump_json_size(size: &mut usize, addition: usize) -> Result<()> {
    *size = size
        .checked_add(addition)
        .ok_or_else(|| Error::javascript("JavaScript result exceeds the size limit"))?;
    if *size > MAX_BRIDGE_BYTES {
        return Err(Error::javascript(
            "JavaScript result exceeds the size limit",
        ));
    }
    Ok(())
}

fn js_call_error(error: rquickjs::Error) -> Error {
    Error::javascript(format!("calling toJSON failed: {error}"))
}

// ---------------------------------------------------------------------------
// Event construction
// ---------------------------------------------------------------------------

/// The operation descriptor flattened into the reducer event.
pub(super) struct OperationSpec<'a> {
    /// Snake-case operation name (`"search"`, `"book_info"`, …).
    pub kind: &'a str,
    /// Operation input as JSON.
    pub input: &'a Value,
}

/// One reducer round: everything the event carries besides the operation.
pub(super) struct Round<'a> {
    pub cursor: &'a Value,
    pub state: Option<OpaqueJsValue>,
    pub compute: Option<OpaqueJsValue>,
    pub response: Option<&'a HttpResponse>,
    pub auth: Option<&'a Value>,
    pub webview: Option<&'a WebviewSnapshot>,
}

/// Build the reducer event object natively.
pub(super) fn build_event<'js>(
    ctx: &Ctx<'js>,
    operation: &OperationSpec<'_>,
    round: &Round<'_>,
) -> rquickjs::Result<JsValue<'js>> {
    let event = Object::new(ctx.clone())?;
    event.set("operation", operation.kind)?;
    event.set("input", json_to_js(ctx, operation.input)?)?;
    event.set("cursor", json_to_js(ctx, round.cursor)?)?;
    match &round.state {
        Some(state) => event.set("state", state.restore(ctx)?)?,
        None => event.set("state", JsValue::new_null(ctx.clone()))?,
    }
    match round.response {
        Some(response) => event.set("response", response_to_js(ctx, response)?)?,
        None => event.set("response", JsValue::new_null(ctx.clone()))?,
    }
    match &round.compute {
        Some(compute) => event.set("compute", compute.restore(ctx)?)?,
        None => event.set("compute", JsValue::new_null(ctx.clone()))?,
    }
    match round.auth {
        Some(auth) => event.set("auth", json_to_js(ctx, auth)?)?,
        None => event.set("auth", JsValue::new_null(ctx.clone()))?,
    }
    match round.webview {
        Some(snapshot) => event.set("webview", webview_to_js(ctx, snapshot)?)?,
        None => event.set("webview", JsValue::new_null(ctx.clone()))?,
    }
    Ok(event.into_value())
}

/// Build a live JavaScript value from JSON-shaped host data.
pub(super) fn json_to_js<'js>(ctx: &Ctx<'js>, value: &Value) -> rquickjs::Result<JsValue<'js>> {
    jsdata_to_js(ctx, &JsData::from_json(value))
}

fn response_to_js<'js>(
    ctx: &Ctx<'js>,
    response: &HttpResponse,
) -> rquickjs::Result<JsValue<'js>> {
    let object = Object::new(ctx.clone())?;
    object.set("status", i32::from(response.status))?;
    let headers = Array::new(ctx.clone())?;
    for (name, value) in &response.headers {
        let pair = Array::new(ctx.clone())?;
        pair.set(0, name.as_str())?;
        pair.set(1, value.as_str())?;
        headers.set(headers.len(), pair)?;
    }
    object.set("headers", headers)?;
    object.set("body", bytes_to_u8array(ctx, &response.body.0)?)?;
    object.set("url", response.url.as_str())?;
    Ok(object.into_value())
}

fn cookie_to_js<'js>(ctx: &Ctx<'js>, cookie: &CookieEntry) -> rquickjs::Result<Object<'js>> {
    let entry = Object::new(ctx.clone())?;
    entry.set("name", cookie.name.as_str())?;
    entry.set("value", cookie.value.as_str())?;
    entry.set("domain", optional_to_js(ctx, &cookie.domain)?)?;
    entry.set("path", optional_to_js(ctx, &cookie.path)?)?;
    entry.set("expires", optional_to_js(ctx, &cookie.expires)?)?;
    entry.set("secure", optional_to_js(ctx, &cookie.secure)?)?;
    entry.set("http_only", optional_to_js(ctx, &cookie.http_only)?)?;
    entry.set("same_site", optional_to_js(ctx, &cookie.same_site)?)?;
    Ok(entry)
}

fn webview_to_js<'js>(
    ctx: &Ctx<'js>,
    snapshot: &WebviewSnapshot,
) -> rquickjs::Result<JsValue<'js>> {
    let object = Object::new(ctx.clone())?;
    object.set("current_url", snapshot.current_url.as_str())?;
    object.set("html", snapshot.html.as_str())?;
    let cookies = Array::new(ctx.clone())?;
    for cookie in &snapshot.cookies {
        cookies.set(cookies.len(), cookie_to_js(ctx, cookie)?)?;
    }
    object.set("cookies", cookies)?;
    Ok(object.into_value())
}

/// Build the page context object handed to `login.parse`.
pub(super) fn build_auth_page<'js>(
    ctx: &Ctx<'js>,
    page: &AuthPageContext,
) -> rquickjs::Result<JsValue<'js>> {
    let object = Object::new(ctx.clone())?;
    object.set("current_url", page.current_url.as_str())?;
    object.set("response", bytes_to_u8array(ctx, &page.response.0)?)?;
    let headers = Array::new(ctx.clone())?;
    for (name, value) in &page.response_headers {
        let pair = Array::new(ctx.clone())?;
        pair.set(0, name.as_str())?;
        pair.set(1, value.as_str())?;
        headers.set(headers.len(), pair)?;
    }
    object.set("response_headers", headers)?;
    let cookies = Array::new(ctx.clone())?;
    for cookie in &page.cookies {
        cookies.set(cookies.len(), cookie_to_js(ctx, cookie)?)?;
    }
    object.set("cookies", cookies)?;
    Ok(object.into_value())
}

fn optional_to_js<'js, T: rquickjs::IntoJs<'js> + Clone>(
    ctx: &Ctx<'js>,
    value: &Option<T>,
) -> rquickjs::Result<JsValue<'js>> {
    match value {
        Some(value) => value.clone().into_js(ctx),
        None => Ok(JsValue::new_null(ctx.clone())),
    }
}

// ---------------------------------------------------------------------------
// Step extraction
// ---------------------------------------------------------------------------

/// A step returned by a reducer, extracted from the live result object.
pub(super) enum Step {
    Request {
        request: HttpRequest,
        next_state: Option<OpaqueJsValue>,
        cache_key: Option<String>,
    },
    Compute {
        programs: Vec<String>,
        input: JsData,
        next_state: Option<OpaqueJsValue>,
    },
    Webview {
        url: String,
        title: Option<String>,
        user_agent: String,
        next_state: Option<OpaqueJsValue>,
    },
    Complete {
        items: Option<Value>,
        value: Option<Value>,
        next_cursor: Option<Value>,
    },
    Fail {
        code: String,
        message: String,
    },
}

/// Read the step a reducer returned from its live result object.
pub(super) fn read_step<'js>(ctx: &Ctx<'js>, value: &JsValue<'js>) -> Result<Step> {
    let Some(object) = value.clone().into_object() else {
        return Err(Error::javascript("invalid feed step: expected an object"));
    };
    let step_type = required_string(&object, "type", "invalid feed step")?;
    match step_type.as_str() {
        "request" => {
            let request_object = required_object(&object, "request", "invalid feed step")?;
            let request = read_http_request(&request_object, "invalid feed step")?;
            let cache_key = optional_string(&object, "cache_key", "invalid feed step")?;
            let next_state = read_next_state(ctx, &object)?;
            Ok(Step::Request {
                request,
                next_state,
                cache_key,
            })
        }
        "compute" => {
            let programs = required_string_array(&object, "programs", "invalid feed step")?;
            let input = {
                let value = get_prop(&object, "input")?;
                if value.is_undefined() {
                    JsData::Null
                } else {
                    js_to_jsdata(&value)?
                }
            };
            let next_state = read_next_state(ctx, &object)?;
            Ok(Step::Compute {
                programs,
                input,
                next_state,
            })
        }
        "webview" => {
            let url = required_string(&object, "url", "invalid feed step")?;
            let title = optional_string(&object, "title", "invalid feed step")?;
            let user_agent = required_string(&object, "user_agent", "invalid feed step")?;
            let next_state = read_next_state(ctx, &object)?;
            Ok(Step::Webview {
                url,
                title,
                user_agent,
                next_state,
            })
        }
        "complete" => {
            let items = json_field(ctx, &object, "items")?;
            let value = json_field(ctx, &object, "value")?;
            let next_cursor = json_field(ctx, &object, "next_cursor")?;
            Ok(Step::Complete {
                items,
                value,
                next_cursor,
            })
        }
        "fail" => {
            let code = required_string(&object, "code", "invalid feed step")?;
            let message = required_string(&object, "message", "invalid feed step")?;
            Ok(Step::Fail { code, message })
        }
        other => Err(Error::javascript(format!(
            "invalid feed step: unknown step type {other:?}"
        ))),
    }
}

/// Build the JavaScript form of an [`HttpRequest`] for `login.patchRequest`.
pub(super) fn build_request_object<'js>(
    ctx: &Ctx<'js>,
    request: &HttpRequest,
) -> rquickjs::Result<JsValue<'js>> {
    let object = Object::new(ctx.clone())?;
    object.set("url", request.url.as_str())?;
    object.set("method", request.method.as_str())?;
    let params = Object::new(ctx.clone())?;
    for (key, value) in &request.params {
        params.set(key.as_str(), value.as_str())?;
    }
    object.set("params", params)?;
    // Headers are presented as a map so feeds can patch them with ordinary
    // property mutation (`request.headers.Authorization = ...`).
    let headers = Object::new(ctx.clone())?;
    for (key, value) in &request.headers {
        headers.set(key.as_str(), value.as_str())?;
    }
    object.set("headers", headers)?;
    match &request.body {
        Some(body) => object.set("body", bytes_to_u8array(ctx, &body.0)?)?,
        None => object.set("body", JsValue::new_null(ctx.clone()))?,
    }
    Ok(object.into_value())
}

/// Read an [`HttpRequest`] from a live object, accepting the same shapes the
/// old serde deserializer did: headers as a map or an array of pairs, body
/// as a string or `Uint8Array`.
pub(super) fn read_http_request(object: &Object<'_>, label: &str) -> Result<HttpRequest> {
    let url = required_string(object, "url", label)?;
    let method = optional_string(object, "method", label)?.unwrap_or_else(|| "GET".to_owned());
    let params = read_params(object, label)?;
    let headers = read_headers(object, label)?;
    let body = read_body(object, label)?;
    Ok(HttpRequest {
        url,
        method,
        params,
        headers,
        body,
    })
}

fn read_params(object: &Object<'_>, label: &str) -> Result<HashMap<String, String>> {
    let value = get_prop(object, "params")?;
    if value.is_undefined() || value.is_null() {
        return Ok(HashMap::new());
    }
    if value.is_array() {
        return Err(field_error(label, "params", "must be an object"));
    }
    let Some(map) = value.clone().into_object() else {
        return Err(field_error(label, "params", "must be an object"));
    };
    let mut params = HashMap::with_capacity(map.len());
    for entry in map.props::<String, JsValue>() {
        let (key, prop) = entry.map_err(|error| {
            Error::javascript(format!("{label}: reading params failed: {error}"))
        })?;
        let text = prop
            .get::<String>()
            .map_err(|_| field_error(label, "params", "values must be strings"))?;
        params.insert(key, text);
    }
    Ok(params)
}

fn read_headers(object: &Object<'_>, label: &str) -> Result<Vec<(String, String)>> {
    let value = get_prop(object, "headers")?;
    if value.is_undefined() || value.is_null() {
        return Ok(Vec::new());
    }
    if value.is_array() {
        let array = value.clone().into_array().ok_or_else(|| {
            Error::javascript(format!("{label}: reading headers failed"))
        })?;
        let mut headers = Vec::with_capacity(array.len());
        for entry in array.iter::<JsValue>() {
            let entry = entry.map_err(|error| {
                Error::javascript(format!("{label}: reading headers failed: {error}"))
            })?;
            let Some(pair) = entry.clone().into_array() else {
                return Err(field_error(label, "headers", "entries must be [name, value] pairs"));
            };
            if pair.len() != 2 {
                return Err(field_error(
                    label,
                    "headers",
                    "entries must have exactly two elements",
                ));
            }
            let name = pair
                .get::<JsValue>(0)
                .ok()
                .and_then(|value| value.get::<String>().ok())
                .ok_or_else(|| {
                    field_error(label, "headers", "entry names must be strings")
                })?;
            let value = pair
                .get::<JsValue>(1)
                .ok()
                .and_then(|value| value.get::<String>().ok())
                .ok_or_else(|| {
                    field_error(label, "headers", "entry values must be strings")
                })?;
            headers.push((name, value));
        }
        return Ok(headers);
    }
    let Some(map) = value.clone().into_object() else {
        return Err(field_error(
            label,
            "headers",
            "must be a map or an array of [name, value] pairs",
        ));
    };
    let mut headers = Vec::with_capacity(map.len());
    for entry in map.props::<String, JsValue>() {
        let (name, prop) = entry.map_err(|error| {
            Error::javascript(format!("{label}: reading headers failed: {error}"))
        })?;
        let value = prop
            .get::<String>()
            .map_err(|_| field_error(label, "headers", "values must be strings"))?;
        headers.push((name, value));
    }
    Ok(headers)
}

fn read_body(object: &Object<'_>, label: &str) -> Result<Option<HttpBody>> {
    let value = get_prop(object, "body")?;
    if value.is_undefined() || value.is_null() {
        return Ok(None);
    }
    if value.is_string() {
        let text = value
            .get::<String>()
            .map_err(|_| field_error(label, "body", "must be a string or Uint8Array"))?;
        return Ok(Some(HttpBody::from_string(text)));
    }
    if let Some(bytes) = u8_to_bytes(&value) {
        return Ok(Some(HttpBody(bytes)));
    }
    Err(field_error(label, "body", "must be a string or Uint8Array"))
}

fn read_next_state<'js>(
    ctx: &Ctx<'js>,
    object: &Object<'js>,
) -> Result<Option<OpaqueJsValue>> {
    let value = get_prop(object, "next_state")?;
    if value.is_undefined() || value.is_null() {
        return Ok(None);
    }
    Ok(Some(OpaqueJsValue::save(ctx, value)))
}

fn json_field<'js>(
    ctx: &Ctx<'js>,
    object: &Object<'js>,
    field: &'static str,
) -> Result<Option<Value>> {
    let value = get_prop(object, field)?;
    if value.is_undefined() || value.is_null() {
        return Ok(None);
    }
    js_to_json(ctx, &value)
        .map_err(|error| Error::javascript(format!("invalid feed step: `{field}`: {error}")))
}

// ---------------------------------------------------------------------------
// Field readers
// ---------------------------------------------------------------------------

fn get_prop<'js>(object: &Object<'js>, field: &str) -> Result<JsValue<'js>> {
    object
        .get::<_, JsValue>(field)
        .map_err(|error| Error::javascript(format!("reading `{field}` failed: {error}")))
}

fn field_error(label: &str, field: &str, problem: &str) -> Error {
    Error::javascript(format!("{label}: `{field}` {problem}"))
}

pub(super) fn required_string(object: &Object<'_>, field: &str, label: &str) -> Result<String> {
    let value = get_prop(object, field)?;
    if value.is_undefined() {
        return Err(Error::javascript(format!(
            "{label}: missing field `{field}`"
        )));
    }
    value
        .get::<String>()
        .map_err(|_| field_error(label, field, "must be a string"))
}

pub(super) fn optional_string(
    object: &Object<'_>,
    field: &str,
    label: &str,
) -> Result<Option<String>> {
    let value = get_prop(object, field)?;
    if value.is_undefined() || value.is_null() {
        return Ok(None);
    }
    value
        .get::<String>()
        .map(Some)
        .map_err(|_| field_error(label, field, "must be a string"))
}

fn required_object<'js>(
    object: &Object<'js>,
    field: &str,
    label: &str,
) -> Result<Object<'js>> {
    let value = get_prop(object, field)?;
    if value.is_undefined() {
        return Err(Error::javascript(format!(
            "{label}: missing field `{field}`"
        )));
    }
    value
        .clone()
        .into_object()
        .ok_or_else(|| field_error(label, field, "must be an object"))
}

fn required_string_array(
    object: &Object<'_>,
    field: &str,
    label: &str,
) -> Result<Vec<String>> {
    let value = get_prop(object, field)?;
    if value.is_undefined() {
        return Err(Error::javascript(format!(
            "{label}: missing field `{field}`"
        )));
    }
    if !value.is_array() {
        return Err(field_error(label, field, "must be an array of strings"));
    }
    let array = value
        .clone()
        .into_array()
        .ok_or_else(|| field_error(label, field, "must be an array of strings"))?;
    let mut items = Vec::with_capacity(array.len());
    for entry in array.iter::<JsValue>() {
        let entry = entry.map_err(|error| {
            Error::javascript(format!("{label}: reading `{field}` failed: {error}"))
        })?;
        let text = entry
            .get::<String>()
            .map_err(|_| field_error(label, field, "must contain only strings"))?;
        items.push(text);
    }
    Ok(items)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn js_data_json_round_trip_preserves_shapes() {
        let json = serde_json::json!({
            "name": "番茄",
            "count": 3,
            "ratio": 0.5,
            "flag": true,
            "empty": null,
            "list": [1, "two", null],
        });
        let data = JsData::from_json(&json);
        assert_eq!(data.into_json(), json);
    }

    #[test]
    fn js_data_measure_counts_payloads() {
        let data = JsData::Obj(vec![(
            "payload".to_owned(),
            JsData::Bytes(Bytes::from_static(&[7; 100])),
        )]);
        assert!(data.measure() >= 100);
    }
}

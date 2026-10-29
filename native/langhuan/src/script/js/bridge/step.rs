//! Reading what scripts return: reducer steps, patched requests, and
//! authentication results.
//!
//! Extraction is strict — every reader names the offending field — because a
//! malformed step must fail loudly, not silently. [`Fields`] carries the
//! context label so the same reader reports as `invalid feed step` inside a
//! step and as `invalid patched request` for a `login.patchRequest` result.

use std::collections::HashMap;

use rquickjs::{Ctx, Object, Value as JsValue};
use serde_json::Value;

use super::convert::{JsData, js_to_jsdata, js_to_json, u8_to_bytes};
use super::event::OpaqueJsValue;
use crate::error::{Error, ExpectedErrorCode, Result};
use crate::feed::AuthEntry;
use crate::http::{HttpBody, HttpRequest};

// ---------------------------------------------------------------------------
// Steps
// ---------------------------------------------------------------------------

/// A step returned by a reducer, extracted from the live result object.
pub enum Step {
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
        next_cursor: Option<JsData>,
    },
    Fail {
        code: String,
        message: String,
    },
}

/// Read the step a reducer returned from its live result object.
pub fn read_step<'js>(ctx: &Ctx<'js>, value: &JsValue<'js>) -> Result<Step> {
    let object = value
        .clone()
        .into_object()
        .ok_or_else(|| Error::javascript("invalid feed step: expected an object"))?;
    let fields = Fields::new(&object, "invalid feed step");
    let step_type = fields.required_string("type")?;
    match step_type.as_str() {
        "request" => {
            let request_object = fields.required_object("request")?;
            let request = read_request(&request_object, "invalid feed step")?;
            let cache_key = fields.optional_string("cache_key")?;
            let next_state = read_next_state(ctx, &fields)?;
            Ok(Step::Request {
                request,
                next_state,
                cache_key,
            })
        }
        "compute" => {
            let programs = fields.string_array("programs")?;
            let input = {
                let value = fields.value("input")?;
                if value.is_undefined() {
                    JsData::Null
                } else {
                    js_to_jsdata(&value)?
                }
            };
            let next_state = read_next_state(ctx, &fields)?;
            Ok(Step::Compute {
                programs,
                input,
                next_state,
            })
        }
        "webview" => {
            let url = fields.required_string("url")?;
            let title = fields.optional_string("title")?;
            let user_agent = fields.required_string("user_agent")?;
            let next_state = read_next_state(ctx, &fields)?;
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
            let next_cursor = data_field(&object, "next_cursor")?;
            Ok(Step::Complete {
                items,
                value,
                next_cursor,
            })
        }
        "fail" => {
            let code = fields.required_string("code")?;
            let message = fields.required_string("message")?;
            Ok(Step::Fail { code, message })
        }
        other => Err(Error::javascript(format!(
            "invalid feed step: unknown step type {other:?}"
        ))),
    }
}

fn read_next_state<'js>(ctx: &Ctx<'js>, fields: &Fields<'js, '_>) -> Result<Option<OpaqueJsValue>> {
    let value = fields.value("next_state")?;
    if value.is_undefined() || value.is_null() {
        return Ok(None);
    }
    Ok(Some(OpaqueJsValue::save(ctx, value)))
}

/// Read a step field as realm-independent data, for values that travel back
/// into the realm untouched (unlike `items`/`value`, which the host
/// materializes as JSON for serde).
fn data_field<'js>(object: &Object<'js>, field: &'static str) -> Result<Option<JsData>> {
    let value: JsValue = object
        .get(field)
        .map_err(|error| Error::javascript(format!("reading `{field}` failed: {error}")))?;
    if value.is_undefined() || value.is_null() {
        return Ok(None);
    }
    js_to_jsdata(&value)
        .map(Some)
        .map_err(|error| Error::javascript(format!("invalid feed step: `{field}`: {error}")))
}

/// Convert a step field to JSON, rejecting bytes and other non-JSON values.
fn json_field<'js>(
    ctx: &Ctx<'js>,
    object: &Object<'js>,
    field: &'static str,
) -> Result<Option<Value>> {
    let value: JsValue = object
        .get(field)
        .map_err(|error| Error::javascript(format!("reading `{field}` failed: {error}")))?;
    if value.is_undefined() || value.is_null() {
        return Ok(None);
    }
    js_to_json(ctx, &value)
        .map_err(|error| Error::javascript(format!("invalid feed step: `{field}`: {error}")))
}

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

/// Read the object `login.patchRequest` returned.
pub fn read_patched_request(value: &JsValue<'_>) -> Result<HttpRequest> {
    let object = value
        .clone()
        .into_object()
        .ok_or_else(|| Error::javascript("invalid patched request: expected an object"))?;
    read_request(&object, "invalid patched request")
}

/// Read an [`HttpRequest`] from a live object, accepting the same shapes the
/// old serde deserializer did: headers as a map or an array of pairs, body
/// as a string or `Uint8Array`.
fn read_request(object: &Object<'_>, label: &'static str) -> Result<HttpRequest> {
    let fields = Fields::new(object, label);
    let url = fields.required_string("url")?;
    let method = fields
        .optional_string("method")?
        .unwrap_or_else(|| "GET".to_owned());
    let params = read_params(&fields)?;
    let headers = read_headers(&fields)?;
    let body = read_body(&fields)?;
    Ok(HttpRequest {
        url,
        method,
        params,
        headers,
        body,
    })
}

fn read_params(fields: &Fields<'_, '_>) -> Result<HashMap<String, String>> {
    let value = fields.value("params")?;
    if value.is_undefined() || value.is_null() {
        return Ok(HashMap::new());
    }
    if value.is_array() {
        return Err(fields.error("params", "must be an object"));
    }
    let Some(map) = value.clone().into_object() else {
        return Err(fields.error("params", "must be an object"));
    };
    let mut params = HashMap::with_capacity(map.len());
    for entry in map.props::<String, JsValue>() {
        let (key, prop) = entry.map_err(|error| {
            Error::javascript(format!("{}: reading params failed: {error}", fields.label))
        })?;
        let text = prop
            .get::<String>()
            .map_err(|_| fields.error("params", "values must be strings"))?;
        params.insert(key, text);
    }
    Ok(params)
}

fn read_headers(fields: &Fields<'_, '_>) -> Result<Vec<(String, String)>> {
    let value = fields.value("headers")?;
    if value.is_undefined() || value.is_null() {
        return Ok(Vec::new());
    }
    if value.is_array() {
        let array = value.clone().into_array().ok_or_else(|| {
            Error::javascript(format!("{}: reading headers failed", fields.label))
        })?;
        let mut headers = Vec::with_capacity(array.len());
        for entry in array.iter::<JsValue>() {
            let entry = entry.map_err(|error| {
                Error::javascript(format!("{}: reading headers failed: {error}", fields.label))
            })?;
            let Some(pair) = entry.clone().into_array() else {
                return Err(fields.error("headers", "entries must be [name, value] pairs"));
            };
            if pair.len() != 2 {
                return Err(fields.error("headers", "entries must have exactly two elements"));
            }
            let name = pair
                .get::<String>(0)
                .ok()
                .ok_or_else(|| fields.error("headers", "entry names must be strings"))?;
            let value = pair
                .get::<String>(1)
                .ok()
                .ok_or_else(|| fields.error("headers", "entry values must be strings"))?;
            headers.push((name, value));
        }
        return Ok(headers);
    }
    let Some(map) = value.clone().into_object() else {
        return Err(fields.error(
            "headers",
            "must be a map or an array of [name, value] pairs",
        ));
    };
    let mut headers = Vec::with_capacity(map.len());
    for entry in map.props::<String, JsValue>() {
        let (name, prop) = entry.map_err(|error| {
            Error::javascript(format!("{}: reading headers failed: {error}", fields.label))
        })?;
        let value = prop
            .get::<String>()
            .map_err(|_| fields.error("headers", "values must be strings"))?;
        headers.push((name, value));
    }
    Ok(headers)
}

fn read_body(fields: &Fields<'_, '_>) -> Result<Option<HttpBody>> {
    let value = fields.value("body")?;
    if value.is_undefined() || value.is_null() {
        return Ok(None);
    }
    if value.is_string() {
        let text = value
            .get::<String>()
            .map_err(|_| fields.error("body", "must be a string or Uint8Array"))?;
        return Ok(Some(HttpBody::from_string(text)));
    }
    if let Some(bytes) = u8_to_bytes(&value) {
        return Ok(Some(HttpBody(bytes)));
    }
    Err(fields.error("body", "must be a string or Uint8Array"))
}

// ---------------------------------------------------------------------------
// Authentication results
// ---------------------------------------------------------------------------

/// Read the object `login.entry` returned.
pub fn read_auth_entry(value: &JsValue<'_>) -> Result<AuthEntry> {
    let object = value
        .clone()
        .into_object()
        .ok_or_else(|| Error::javascript("invalid auth entry: expected an object"))?;
    let fields = Fields::new(&object, "invalid auth entry");
    Ok(AuthEntry {
        url: fields.required_string("url")?,
        title: fields.optional_string("title")?,
        user_agent: fields.required_string("user_agent")?,
    })
}

/// Read what `login.parse` returned: either a fail step the host lifts into
/// an expected error, or the auth payload as JSON.
pub fn read_auth_result<'js>(ctx: &Ctx<'js>, value: &JsValue<'js>) -> Result<Value> {
    if let Some(object) = value.clone().into_object()
        && let Ok(step_type) = object.get::<_, String>("type")
        && step_type == "fail"
    {
        let code = object
            .get::<_, String>("code")
            .unwrap_or_else(|_| "raise".to_owned());
        let message = object
            .get::<_, String>("message")
            .unwrap_or_else(|_| "authentication failed".to_owned());
        return Err(Error::expected(
            ExpectedErrorCode::from_code(&code),
            message,
        ));
    }
    match js_to_json(ctx, value) {
        Ok(Some(value)) => Ok(value),
        Ok(None) => Err(Error::javascript(
            "invalid authentication result: method returned undefined",
        )),
        Err(error) => Err(Error::javascript(format!(
            "invalid authentication result: {error}"
        ))),
    }
}

// ---------------------------------------------------------------------------
// Field readers
// ---------------------------------------------------------------------------

/// Labeled field readers over a live object, so extraction errors name both
/// the context (`"invalid feed step"`) and the offending field.
struct Fields<'js, 'a> {
    object: &'a Object<'js>,
    label: &'static str,
}

impl<'js, 'a> Fields<'js, 'a> {
    fn new(object: &'a Object<'js>, label: &'static str) -> Self {
        Self { object, label }
    }

    /// Fetch a field's live value.
    fn value(&self, field: &str) -> Result<JsValue<'js>> {
        self.object.get::<_, JsValue>(field).map_err(|error| {
            Error::javascript(format!("{}: reading `{field}` failed: {error}", self.label))
        })
    }

    fn missing(&self, field: &str) -> Error {
        Error::javascript(format!("{}: missing field `{field}`", self.label))
    }

    fn error(&self, field: &str, problem: &str) -> Error {
        Error::javascript(format!("{}: `{field}` {problem}", self.label))
    }

    fn required_string(&self, field: &str) -> Result<String> {
        let value = self.value(field)?;
        if value.is_undefined() {
            return Err(self.missing(field));
        }
        value
            .get::<String>()
            .map_err(|_| self.error(field, "must be a string"))
    }

    fn optional_string(&self, field: &str) -> Result<Option<String>> {
        let value = self.value(field)?;
        if value.is_undefined() || value.is_null() {
            return Ok(None);
        }
        value
            .get::<String>()
            .map(Some)
            .map_err(|_| self.error(field, "must be a string"))
    }

    fn required_object(&self, field: &str) -> Result<Object<'js>> {
        let value = self.value(field)?;
        if value.is_undefined() {
            return Err(self.missing(field));
        }
        value
            .into_object()
            .ok_or_else(|| self.error(field, "must be an object"))
    }

    fn string_array(&self, field: &str) -> Result<Vec<String>> {
        let value = self.value(field)?;
        if value.is_undefined() {
            return Err(self.missing(field));
        }
        if !value.is_array() {
            return Err(self.error(field, "must be an array of strings"));
        }
        let array = value
            .into_array()
            .ok_or_else(|| self.error(field, "must be an array of strings"))?;
        let mut items = Vec::with_capacity(array.len());
        for entry in array.iter::<JsValue>() {
            let entry = entry.map_err(|error| {
                Error::javascript(format!("{}: reading `{field}` failed: {error}", self.label))
            })?;
            let text = entry
                .get::<String>()
                .map_err(|_| self.error(field, "must contain only strings"))?;
            items.push(text);
        }
        Ok(items)
    }
}

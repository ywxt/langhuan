//! Reading what scripts return: reducer steps, patched requests, and
//! authentication results.
//!
//! Extraction is strict — every reader names the offending field — because a
//! malformed step must fail loudly, not silently. Each shape implements
//! [`FromJs`] and carries the field-level detail in the conversion error's
//! message slot; the boundary functions extract that detail and prefix the
//! context label, so the same reader reports as `invalid feed step` inside a
//! step and as `invalid patched request` for a `login.patchRequest` result.

use std::collections::HashMap;

use rquickjs::{Ctx, Error as JsError, FromJs, Result as JsResult, Value as JsValue};
use serde_json::Value;

use super::convert::{JsData, js_to_jsdata, js_to_json, u8_to_bytes};
use super::event::OpaqueJsValue;
use super::fields::{Fields, conversion_detail};
use crate::error::{Error, ExpectedErrorCode, Result};
use crate::feed::AuthEntry;
use crate::http::{HttpBody, HttpRequest};

// ---------------------------------------------------------------------------
// Steps
// ---------------------------------------------------------------------------

/// A step returned by a reducer, extracted from the live result object.
#[derive(Debug)]
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
    Step::from_js(ctx, value.clone()).map_err(|error| labeled("invalid feed step", error))
}

impl<'js> FromJs<'js> for Step {
    fn from_js(ctx: &Ctx<'js>, value: JsValue<'js>) -> JsResult<Self> {
        let fields = Fields::new(value, "Step")?;
        let step_type = fields.required_string("type")?;
        match step_type.as_str() {
            "request" => {
                let request_object = fields.required_object("request")?;
                let request = HttpRequest::from_js(ctx, request_object.into_value())?;
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
                        js_to_jsdata(&value)
                            .map_err(|error| fields.conversion_error("input", error))?
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
                let items = fields.json_field(ctx, "items")?;
                let value = fields.json_field(ctx, "value")?;
                let next_cursor = fields.data_field("next_cursor")?;
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
            other => Err(fields.invalid(format!("unknown step type {other:?}"))),
        }
    }
}

fn read_next_state<'js>(ctx: &Ctx<'js>, fields: &Fields<'js>) -> JsResult<Option<OpaqueJsValue>> {
    let value = fields.value("next_state")?;
    if value.is_undefined() || value.is_null() {
        return Ok(None);
    }
    Ok(Some(OpaqueJsValue::save(ctx, value)))
}

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

/// Read the object `login.patchRequest` returned.
pub fn read_patched_request(value: &JsValue<'_>) -> Result<HttpRequest> {
    HttpRequest::from_js(value.ctx(), value.clone())
        .map_err(|error| labeled("invalid patched request", error))
}

/// Read an [`HttpRequest`] from a live object, accepting the same shapes the
/// old serde deserializer did: headers as a map or an array of pairs, body
/// as a string or `Uint8Array`.
impl<'js> FromJs<'js> for HttpRequest {
    fn from_js(_ctx: &Ctx<'js>, value: JsValue<'js>) -> JsResult<Self> {
        let fields = Fields::new(value, "HttpRequest")?;
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
}

fn read_params(fields: &Fields<'_>) -> JsResult<HashMap<String, String>> {
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
        let (key, prop) =
            entry.map_err(|error| fields.invalid(format!("reading params failed: {error}")))?;
        let text = prop
            .get::<String>()
            .map_err(|_| fields.error("params", "values must be strings"))?;
        params.insert(key, text);
    }
    Ok(params)
}

fn read_headers(fields: &Fields<'_>) -> JsResult<Vec<(String, String)>> {
    let value = fields.value("headers")?;
    if value.is_undefined() || value.is_null() {
        return Ok(Vec::new());
    }
    if value.is_array() {
        let array = value
            .clone()
            .into_array()
            .ok_or_else(|| fields.invalid("reading headers failed"))?;
        let mut headers = Vec::with_capacity(array.len());
        for entry in array.iter::<JsValue>() {
            let entry = entry
                .map_err(|error| fields.invalid(format!("reading headers failed: {error}")))?;
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
        let (name, prop) =
            entry.map_err(|error| fields.invalid(format!("reading headers failed: {error}")))?;
        let value = prop
            .get::<String>()
            .map_err(|_| fields.error("headers", "values must be strings"))?;
        headers.push((name, value));
    }
    Ok(headers)
}

fn read_body(fields: &Fields<'_>) -> JsResult<Option<HttpBody>> {
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
    AuthEntry::from_js(value.ctx(), value.clone())
        .map_err(|error| labeled("invalid auth entry", error))
}

impl<'js> FromJs<'js> for AuthEntry {
    fn from_js(_ctx: &Ctx<'js>, value: JsValue<'js>) -> JsResult<Self> {
        let fields = Fields::new(value, "AuthEntry")?;
        Ok(AuthEntry {
            url: fields.required_string("url")?,
            title: fields.optional_string("title")?,
            user_agent: fields.required_string("user_agent")?,
        })
    }
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
// Conversion errors
// ---------------------------------------------------------------------------

/// Prefix a context label to a conversion failure; the field-level detail
/// comes from the conversion error's message slot.
fn labeled(label: &'static str, error: JsError) -> Error {
    Error::javascript(format!("{label}: {}", conversion_detail(error)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ScriptError;
    use crate::script::js::sandbox::Sandbox;
    use std::time::Duration;

    /// Evaluate `code` in a feed realm and read it as a step, returning the
    /// failure message.
    fn step_error(code: &str) -> String {
        let mut sandbox = Sandbox::new(Duration::from_secs(5)).unwrap();
        let object = sandbox.eval_object(code).unwrap();
        let error = object
            .with_realm(|ctx, object| Ok(read_step(&ctx, &object.into_value())))
            .expect_err("step unexpectedly read");
        javascript_message(error)
    }

    /// Evaluate `code` in a feed realm and read it as a patched request,
    /// returning the failure message.
    fn request_error(code: &str) -> String {
        let mut sandbox = Sandbox::new(Duration::from_secs(5)).unwrap();
        let object = sandbox.eval_object(code).unwrap();
        let error = object
            .with_realm(|_ctx, object| Ok(read_patched_request(&object.into_value())))
            .expect_err("request unexpectedly read");
        javascript_message(error)
    }

    fn javascript_message(error: Error) -> String {
        match error {
            Error::Script(ScriptError::JavaScript(message)) => message,
            other => panic!("unexpected error kind: {other}"),
        }
    }

    #[test]
    fn step_errors_name_the_offending_field() {
        assert_eq!(
            step_error("({})"),
            "invalid feed step: missing field `type`"
        );
        assert_eq!(
            step_error("({ type: 5 })"),
            "invalid feed step: `type` must be a string"
        );
        assert_eq!(
            step_error("({ type: 'compute', programs: 5 })"),
            "invalid feed step: `programs` must be an array of strings"
        );
        assert_eq!(
            step_error("({ type: 'explode' })"),
            "invalid feed step: unknown step type \"explode\""
        );
    }

    #[test]
    fn step_errors_reach_into_nested_requests() {
        assert_eq!(
            step_error("({ type: 'request', request: 5 })"),
            "invalid feed step: `request` must be an object"
        );
        assert_eq!(
            step_error("({ type: 'request', request: {} })"),
            "invalid feed step: missing field `url`"
        );
        assert_eq!(
            step_error("({ type: 'request', request: { url: 5 } })"),
            "invalid feed step: `url` must be a string"
        );
    }

    #[test]
    fn compute_inputs_tunnel_conversion_failures() {
        assert_eq!(
            step_error("({ type: 'compute', programs: [], input: () => {} })"),
            "invalid feed step: `input`: javascript error: functions cannot be copied across realms"
        );
    }

    #[test]
    fn patched_requests_report_their_own_label() {
        assert_eq!(
            request_error("({ url: 5 })"),
            "invalid patched request: `url` must be a string"
        );
    }

    #[test]
    fn non_object_steps_report_the_expected_shape() {
        let mut sandbox = Sandbox::new(Duration::from_secs(5)).unwrap();
        let object = sandbox.eval_object("({})").unwrap();
        let error = object
            .with_realm(|ctx, _object| {
                let value: JsValue = ctx.eval("5")?;
                Ok(read_step(&ctx, &value))
            })
            .expect_err("step unexpectedly read");
        assert_eq!(
            javascript_message(error),
            "invalid feed step: expected an object"
        );
    }
}

//! Reading what scripts return: reducer steps, patched requests, and
//! authentication results.
//!
//! Extraction is strict — every reader names the offending field — because a
//! malformed step must fail loudly, not silently. Each shape implements
//! [`FromJs`] and carries the field-level detail in the conversion error's
//! message slot; the boundary functions extract that detail and prefix the
//! context label, so the same reader reports as `invalid feed step` inside a
//! step and as `invalid patched request` for a `login.patchRequest` result.

use rquickjs::{Ctx, Error as JsError, FromJs, Result as JsResult, Value as JsValue};
use serde_json::Value;

use super::convert::{JsData, js_to_jsdata, js_to_json};
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
        result: Value,
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
                if cache_key
                    .as_ref()
                    .is_some_and(|key| key.is_empty() || key.len() > 128)
                {
                    return Err(fields.error("cache_key", "must contain 1 to 128 bytes"));
                }
                let next_state = read_next_state(ctx, &fields)?;
                Ok(Step::Request {
                    request,
                    next_state,
                    cache_key,
                })
            }
            "compute" => {
                let programs = fields.string_array("programs")?;
                let input = js_to_jsdata(&fields.value("input")?)
                    .map_err(|error| fields.conversion_error("input", error))?;
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
            "complete" => Ok(Step::Complete {
                result: fields.required_json(ctx, "result")?,
                next_cursor: fields
                    .optional_json(ctx, "next_cursor")?
                    .as_ref()
                    .map(JsData::from_json),
            }),

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

/// Request headers are a string map; request bodies are optional Uint8Array.
impl<'js> FromJs<'js> for HttpRequest {
    fn from_js(ctx: &Ctx<'js>, value: JsValue<'js>) -> JsResult<Self> {
        let fields = Fields::new(value, "HttpRequest")?;
        let url = fields.required_string("url")?;
        let method = fields
            .optional_string("method")?
            .unwrap_or_else(|| "GET".to_owned());
        // Requests no longer carry `params`; scripts build the full URL.
        // Reject the removed field instead of silently dropping it. The
        // migration hint lives at the schema gate in the engine, not here.
        let leftover = fields.value("params")?;
        if !leftover.is_undefined() && !leftover.is_null() {
            return Err(fields.error("params", "is not part of a request"));
        }
        let headers = read_headers(&fields)?;
        let body = fields
            .optional_bytes(ctx, "body")?
            .map(|bytes| HttpBody(bytes.into()));
        Ok(HttpRequest {
            url,
            method,
            headers,
            body,
        })
    }
}

fn read_headers(fields: &Fields<'_>) -> JsResult<Vec<(String, String)>> {
    let value = fields.value("headers")?;
    if value.is_undefined() || value.is_null() {
        return Ok(Vec::new());
    }
    if value.is_array() {
        return Err(fields.error("headers", "must be an object"));
    }
    let Some(map) = value.clone().into_object() else {
        return Err(fields.error("headers", "must be an object"));
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
        let Step::Fail { code, message } = read_step(ctx, value)? else {
            unreachable!()
        };
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
    fn omitted_compute_input_preserves_undefined() {
        let mut sandbox = Sandbox::new(Duration::from_secs(5)).unwrap();
        let object = sandbox
            .eval_object("({type:'compute', programs:['export default typeof input']})")
            .unwrap();
        object
            .with_realm(|ctx, object| {
                let step = read_step(&ctx, &object.into_value()).unwrap();
                assert!(matches!(
                    step,
                    Step::Compute {
                        input: JsData::Undefined,
                        ..
                    }
                ));
                Ok(Ok(()))
            })
            .unwrap();
    }

    #[test]
    fn completion_has_one_required_result_and_json_cursor() {
        assert_eq!(
            step_error("({type:'complete', items:[]})"),
            "invalid feed step: missing field `result`"
        );
        assert_eq!(
            step_error("({type:'complete', result:undefined})"),
            "invalid feed step: missing field `result`"
        );
        assert!(
            step_error("({type:'complete', result:[], next_cursor:new Uint8Array([1])})")
                .contains("next_cursor")
        );

        let mut sandbox = Sandbox::new(Duration::from_secs(5)).unwrap();
        let object = sandbox
            .eval_object("({type:'complete', result:null, next_cursor:{page:2}})")
            .unwrap();
        object
            .with_realm(|ctx, object| {
                let Step::Complete {
                    result,
                    next_cursor,
                } = read_step(&ctx, &object.into_value()).unwrap()
                else {
                    panic!("expected complete step");
                };
                assert!(result.is_null());
                assert_eq!(
                    next_cursor.unwrap().into_json(),
                    serde_json::json!({"page":2})
                );
                Ok(Ok(()))
            })
            .unwrap();
    }

    #[test]
    fn requests_reject_text_bodies_and_pair_array_headers() {
        assert_eq!(
            request_error("({url:'https://example.com', body:'text'})"),
            "invalid patched request: `body` must be a Uint8Array"
        );
        assert_eq!(
            request_error("({url:'https://example.com', headers:[['X','Y']]})"),
            "invalid patched request: `headers` must be an object"
        );
    }

    #[test]
    fn requests_reject_leftover_params() {
        assert_eq!(
            request_error("({url:'https://example.com', params: {q: 'x'}})"),
            "invalid patched request: `params` is not part of a request"
        );
        // Explicitly empty `params` stays accepted, like other optional fields.
        let mut sandbox = Sandbox::new(Duration::from_secs(5)).unwrap();
        let object = sandbox
            .eval_object("({url:'https://example.com', params: null})")
            .unwrap();
        object
            .with_realm(|_ctx, object| Ok(read_patched_request(&object.into_value())))
            .unwrap();
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

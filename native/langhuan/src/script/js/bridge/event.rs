//! The objects the host hands into the realm: the reducer event, the auth
//! page, and patchable requests. All are built as live JavaScript values
//! through the rquickjs [`IntoJs`] trait, so no JSON round trip stands
//! between host data and the script that consumes it.

use rquickjs::{Array, Ctx, IntoJs, Object, Persistent, Value as JsValue};
use serde_json::Value;

use super::convert::{JsData, bytes_to_u8array};
use crate::feed::{AuthPageContext, CookieEntry, WebviewSnapshot};
use crate::http::{HttpRequest, HttpResponse};

// ---------------------------------------------------------------------------
// Opaque values
// ---------------------------------------------------------------------------

/// A persistent JavaScript value carried across `.await` points between
/// reducer rounds.
///
/// QuickJS persistents are not `Send`. This wrapper moves them the same way
/// [`JsObject`](crate::script::js::sandbox::JsObject) moves its realm state:
/// the wrapped value is only restored or saved while the realm mutex is
/// held, so no two threads ever touch the same context through it.
pub struct OpaqueJsValue(Persistent<JsValue<'static>>);

// SAFETY: the persistent is only restored inside `JsObject::with_realm`,
// which serializes all context access behind one mutex. Moving the wrapper
// between threads never touches the QuickJS heap.
unsafe impl Send for OpaqueJsValue {}

impl OpaqueJsValue {
    pub fn save<'js>(ctx: &Ctx<'js>, value: JsValue<'js>) -> Self {
        Self(Persistent::save(ctx, value))
    }

    fn restore<'js>(&self, ctx: &Ctx<'js>) -> rquickjs::Result<JsValue<'js>> {
        self.0.clone().restore(ctx)
    }
}

/// Restore an opaque value into the realm it is consumed in.
impl<'js> IntoJs<'js> for &OpaqueJsValue {
    fn into_js(self, ctx: &Ctx<'js>) -> rquickjs::Result<JsValue<'js>> {
        self.restore(ctx)
    }
}

// ---------------------------------------------------------------------------
// The reducer event
// ---------------------------------------------------------------------------

/// The operation descriptor flattened into the reducer event.
pub struct OperationSpec<'a> {
    /// Snake-case operation name (`"search"`, `"book_info"`, …).
    pub kind: &'a str,
    /// Operation input as JSON.
    pub input: &'a Value,
}

/// What the previously executed step produced, carried into the next round.
/// Every round follows a single step, so the three outcomes are mutually
/// exclusive; `None` means this is the first call.
pub enum StepOutcome {
    Response(HttpResponse),
    Compute(OpaqueJsValue),
    Webview(WebviewSnapshot),
}

/// One reducer round: everything the event carries besides the operation.
pub struct Round<'a> {
    pub cursor: &'a Value,
    pub state: Option<OpaqueJsValue>,
    pub outcome: Option<StepOutcome>,
    pub auth: Option<&'a Value>,
}

/// Build the reducer event object natively.
///
/// Absent round data reads as `undefined`, so scripts test it with loose
/// equality (`event.state == null`), which matches `null` as well.
pub fn build_event<'js>(
    ctx: &Ctx<'js>,
    operation: &OperationSpec<'_>,
    round: &Round<'_>,
) -> rquickjs::Result<JsValue<'js>> {
    let event = Object::new(ctx.clone())?;
    event.set("operation", operation.kind)?;
    event.set("input", JsData::from_json(operation.input))?;
    event.set("cursor", JsData::from_json(round.cursor))?;
    event.set("state", round.state.as_ref())?;
    match round.outcome.as_ref() {
        Some(StepOutcome::Response(response)) => event.set("response", response)?,
        Some(StepOutcome::Compute(compute)) => event.set("compute", compute)?,
        Some(StepOutcome::Webview(webview)) => event.set("webview", webview)?,
        None => {}
    }
    event.set("auth", round.auth.map(JsData::from_json))?;
    Ok(event.into_value())
}

// ---------------------------------------------------------------------------
// Host data as live objects
// ---------------------------------------------------------------------------

/// The `event.response` object: status, header pairs, and the raw body.
impl<'js> IntoJs<'js> for &HttpResponse {
    fn into_js(self, ctx: &Ctx<'js>) -> rquickjs::Result<JsValue<'js>> {
        let object = Object::new(ctx.clone())?;
        object.set("status", i32::from(self.status))?;
        object.set("headers", header_pairs(ctx, &self.headers)?)?;
        object.set("body", bytes_to_u8array(ctx, &self.body.0)?)?;
        object.set("url", self.url.as_str())?;
        Ok(object.into_value())
    }
}

/// The `event.webview` object: the final page state after a login flow.
impl<'js> IntoJs<'js> for &WebviewSnapshot {
    fn into_js(self, ctx: &Ctx<'js>) -> rquickjs::Result<JsValue<'js>> {
        let object = Object::new(ctx.clone())?;
        object.set("current_url", self.current_url.as_str())?;
        object.set("html", self.html.as_str())?;
        object.set("cookies", cookie_array(ctx, &self.cookies)?)?;
        Ok(object.into_value())
    }
}

/// The page context object handed to `login.parse`.
impl<'js> IntoJs<'js> for &AuthPageContext {
    fn into_js(self, ctx: &Ctx<'js>) -> rquickjs::Result<JsValue<'js>> {
        let object = Object::new(ctx.clone())?;
        object.set("current_url", self.current_url.as_str())?;
        object.set("response", bytes_to_u8array(ctx, &self.response.0)?)?;
        object.set(
            "response_headers",
            header_pairs(ctx, &self.response_headers)?,
        )?;
        object.set("cookies", cookie_array(ctx, &self.cookies)?)?;
        Ok(object.into_value())
    }
}

/// The JavaScript form of an [`HttpRequest`] for `login.patchRequest`.
impl<'js> IntoJs<'js> for &HttpRequest {
    fn into_js(self, ctx: &Ctx<'js>) -> rquickjs::Result<JsValue<'js>> {
        let object = Object::new(ctx.clone())?;
        object.set("url", self.url.as_str())?;
        object.set("method", self.method.as_str())?;
        let params = Object::new(ctx.clone())?;
        for (key, value) in &self.params {
            params.set(key.as_str(), value.as_str())?;
        }
        object.set("params", params)?;
        // Headers are presented as a map so feeds can patch them with
        // ordinary property mutation (`request.headers.Authorization = ...`).
        let headers = Object::new(ctx.clone())?;
        for (key, value) in &self.headers {
            headers.set(key.as_str(), value.as_str())?;
        }
        object.set("headers", headers)?;
        if let Some(body) = &self.body {
            object.set("body", bytes_to_u8array(ctx, &body.0)?)?;
        }
        Ok(object.into_value())
    }
}

/// Headers as `[name, value]` pairs, the shape `event.response.headers` and
/// the auth page use.
fn header_pairs<'js>(ctx: &Ctx<'js>, headers: &[(String, String)]) -> rquickjs::Result<Array<'js>> {
    let array = Array::new(ctx.clone())?;
    for (name, value) in headers {
        let pair = Array::new(ctx.clone())?;
        pair.set(0, name.as_str())?;
        pair.set(1, value.as_str())?;
        array.set(array.len(), pair)?;
    }
    Ok(array)
}

fn cookie_array<'js>(ctx: &Ctx<'js>, cookies: &[CookieEntry]) -> rquickjs::Result<Array<'js>> {
    let array = Array::new(ctx.clone())?;
    for cookie in cookies {
        array.set(array.len(), cookie_to_js(ctx, cookie)?)?;
    }
    Ok(array)
}

fn cookie_to_js<'js>(ctx: &Ctx<'js>, cookie: &CookieEntry) -> rquickjs::Result<Object<'js>> {
    let entry = Object::new(ctx.clone())?;
    entry.set("name", cookie.name.as_str())?;
    entry.set("value", cookie.value.as_str())?;
    entry.set("domain", cookie.domain.as_deref())?;
    entry.set("path", cookie.path.as_deref())?;
    entry.set("expires", cookie.expires.as_deref())?;
    entry.set("secure", cookie.secure)?;
    entry.set("http_only", cookie.http_only)?;
    entry.set("same_site", cookie.same_site.as_deref())?;
    Ok(entry)
}

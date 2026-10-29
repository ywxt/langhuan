//! Structured value bridge between Rust and the sandboxed QuickJS realms.
//!
//! The reducer call boundary used to round-trip every argument and result
//! through JSON (`serde → string → json_parse → call → json_stringify →
//! serde`), which silently dropped `undefined`, mangled typed arrays, threw
//! on BigInt, and capped every result by stringified size. This module
//! replaces that boundary with direct value construction and typed readers:
//!
//! * [`convert`] materializes values between JavaScript, [`JsData`], and
//!   JSON, and implements the rquickjs conversion traits so host data
//!   becomes a live object instead of a stringified one.
//! * [`event`] builds the objects the host hands into the realm — the
//!   reducer event, the auth page, and patchable requests.
//! * [`step`] reads what scripts return — reducer steps, patched requests,
//!   and authentication results — with errors that name the offending field.
//!
//! This file holds the call surface the feed drives: resolving a handler,
//! calling it with live values, and carrying results between rounds.

mod convert;
mod event;
mod step;

use rquickjs::{Ctx, IntoJs, Object, Value as JsValue};

use super::sandbox::{JsObject, resolve_owner};
use crate::error::Result;

#[cfg(test)]
pub(super) use convert::js_to_json;
pub(super) use convert::{JsData, Json, js_to_jsdata, typed_bytes};
pub(super) use event::{OpaqueJsValue, OperationSpec, Round, build_event};
pub(super) use step::{Step, read_auth_entry, read_auth_result, read_patched_request, read_step};

/// Upper bound for values materialized across the bridge, matching the
/// serialized-result limit the old JSON boundary enforced.
pub(super) const MAX_BRIDGE_BYTES: usize = 16 * 1024 * 1024;

/// Resolve a method path on the feed object and call it with `this` bound to
/// its owner.
pub(super) fn call_handler<'js>(
    ctx: &Ctx<'js>,
    feed_object: &Object<'js>,
    path: &[&str],
    arguments: &[JsValue<'js>],
) -> rquickjs::Result<JsValue<'js>> {
    let (owner, name) = resolve_owner(feed_object.clone(), path)?.ok_or_else(|| {
        rquickjs::Error::new_from_js_message(
            "object",
            "function",
            format!("missing JavaScript method: {}", path.join(".")),
        )
    })?;
    let function: rquickjs::Function = owner.get(name.as_str())?;
    let mut call_arguments = rquickjs::function::Args::new(ctx.clone(), arguments.len());
    call_arguments.this(owner)?;
    for argument in arguments {
        call_arguments.push_arg(argument.clone())?;
    }
    function.call_arg(call_arguments)
}

/// Materialize a compute result back into the feed realm as an opaque value.
///
/// The result crossed realms as [`JsData`] because the compute realm is
/// disposable; here it becomes a live value again, saved as an
/// [`OpaqueJsValue`] so the next reducer round sees the very same object.
pub(super) fn restore_compute(feed_object: &JsObject, data: &JsData) -> Result<OpaqueJsValue> {
    feed_object.with_realm_js(|ctx, _| {
        let value = data.into_js(&ctx)?;
        Ok(OpaqueJsValue::save(&ctx, value))
    })
}

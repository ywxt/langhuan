//! The `langhuan:storage` module: persistent per-feed key-value storage.
//!
//! Unlike the other host modules — pure functions over their arguments —
//! storage persists: values written here outlive the realm that wrote them.
//! The module is therefore declared only for feeds whose host installed a
//! backend ([`crate::feed::StorageHandler`]); importing it elsewhere fails
//! at link time, so a realm's declared-module list stays its capability
//! list.
//!
//! The backend is wired in at feed bootstrap under an internal global that
//! this module takes over on first import — and that the bootstrap removes
//! if the feed never imports it — so scripts reach storage only through
//! `import { storage } from "langhuan:storage"`, never through a host
//! global. Every call carries the calling feed's identifier, and the host
//! backend namespaces by it: a feed sees only its own keys.

use std::sync::Arc;

use rquickjs::module::{Declarations, Exports, ModuleDef};
use rquickjs::{Ctx, Exception, Object, Result as JsResult, Value as JsValue};

use super::bridge::{JsData, js_to_json};
use super::module::{declare_module, set_function};
use crate::feed::SharedStorageHandler;

/// The bootstrap global the backend is wired under and this module takes
/// over; scripts never see it.
pub(super) const WIRING_GLOBAL: &str = "__langhuan_storage";

/// Upper bound on a storage key: keys become database identifiers, and a
/// runaway key should fail at the boundary, not in the host backend.
const MAX_KEY_BYTES: usize = 256;

/// The `langhuan:storage` module: `storage`.
struct StorageModule;

impl ModuleDef for StorageModule {
    fn declare<'js>(declarations: &Declarations<'js>) -> JsResult<()> {
        declarations.declare("storage")?;
        Ok(())
    }

    fn evaluate<'js>(ctx: &Ctx<'js>, exports: &Exports<'js>) -> JsResult<()> {
        let backend: Option<Object<'js>> = ctx.globals().get(WIRING_GLOBAL)?;
        let Some(backend) = backend else {
            return Err(Exception::throw_message(
                ctx,
                "langhuan:storage: declared without a storage backend",
            ));
        };
        ctx.globals().remove(WIRING_GLOBAL)?;
        exports.export("storage", backend)?;
        Ok(())
    }
}

/// Declare the `langhuan:storage` module in the realm (feed bootstrap only).
pub(super) fn declare<'js>(ctx: &Ctx<'js>) -> JsResult<()> {
    declare_module::<StorageModule>(ctx, "langhuan:storage")
}

/// Build the `storage` object: `get`/`set`/`delete` closing over the host
/// backend and the calling feed's identifier. The calls follow the
/// `localStorage` shape — `get` returns the stored value or `undefined`,
/// `set` and `delete` return nothing and fail by throwing.
pub(super) fn backend<'js>(
    ctx: &Ctx<'js>,
    handler: SharedStorageHandler,
    feed_id: &str,
) -> JsResult<Object<'js>> {
    let storage = Object::new(ctx.clone())?;

    let get = (feed_id.to_owned(), Arc::clone(&handler));
    set_function(
        ctx,
        &storage,
        "get",
        move |ctx: Ctx<'js>, key: String| -> JsResult<Option<JsData>> {
            let (feed_id, handler) = &get;
            validate_key(&ctx, &key, "storage.get")?;
            let value = handler
                .get(feed_id, &key)
                .map_err(|error| Exception::throw_message(&ctx, &error.to_string()))?;
            Ok(value.map(|value| JsData::from_json(&value)))
        },
    )?;

    let set = (feed_id.to_owned(), Arc::clone(&handler));
    set_function(
        ctx,
        &storage,
        "set",
        move |ctx: Ctx<'js>, key: String, value: JsValue<'js>| -> JsResult<()> {
            let (feed_id, handler) = &set;
            validate_key(&ctx, &key, "storage.set")?;
            let value = js_to_json(&ctx, &value)
                .map_err(|error| Exception::throw_message(&ctx, &error.to_string()))?;
            let Some(value) = value else {
                return Err(Exception::throw_message(
                    &ctx,
                    "storage.set: `value` must not be undefined",
                ));
            };
            handler
                .set(feed_id, &key, value)
                .map_err(|error| Exception::throw_message(&ctx, &error.to_string()))
        },
    )?;

    let delete = (feed_id.to_owned(), handler);
    set_function(
        ctx,
        &storage,
        "delete",
        move |ctx: Ctx<'js>, key: String| -> JsResult<()> {
            let (feed_id, handler) = &delete;
            validate_key(&ctx, &key, "storage.delete")?;
            handler
                .delete(feed_id, &key)
                .map_err(|error| Exception::throw_message(&ctx, &error.to_string()))
        },
    )?;

    Ok(storage)
}

/// Reject keys outside the persisted-key budget.
fn validate_key<'js>(ctx: &Ctx<'js>, key: &str, label: &str) -> JsResult<()> {
    if key.is_empty() || key.len() > MAX_KEY_BYTES {
        return Err(Exception::throw_message(
            ctx,
            &format!("{label}: `key` must be between 1 and {MAX_KEY_BYTES} bytes"),
        ));
    }
    Ok(())
}

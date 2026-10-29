//! Registration for host-provided module globals.
//!
//! A host module is a set of pure functions under one global name
//! (`Crypto`, `Bytes`, …) or a constructor global (`TextDecoder`). The
//! builders here keep registration declarative — a module file lists its
//! surface as one chain instead of repeating the create-object /
//! wrap-function / set-property ceremony — and per-object methods go
//! through the same [`set_function`] choke point.

use rquickjs::function::IntoJsFunc;
use rquickjs::{Ctx, Function, Object, Result as JsResult};

/// A function namespace under construction, installed as one global.
pub(super) struct Namespace<'js> {
    ctx: Ctx<'js>,
    name: &'static str,
    object: Object<'js>,
}

impl<'js> Namespace<'js> {
    /// Start the namespace installed as the global `name`.
    pub(super) fn new(ctx: &Ctx<'js>, name: &'static str) -> JsResult<Self> {
        Ok(Self {
            ctx: ctx.clone(),
            name,
            object: Object::new(ctx.clone())?,
        })
    }

    /// Wrap `function` and register it under `name`.
    pub(super) fn function<P, F>(self, name: &'static str, function: F) -> JsResult<Self>
    where
        F: IntoJsFunc<'js, P> + 'js,
    {
        set_function(&self.ctx, &self.object, name, function)?;
        Ok(self)
    }

    /// Install the namespace as a global under its name.
    pub(super) fn install(self) -> JsResult<()> {
        self.ctx.globals().set(self.name, self.object)
    }
}

/// Install a constructor global, callable with `new`; `function` builds the
/// instance object.
pub(super) fn constructor<'js, P, F>(
    ctx: &Ctx<'js>,
    name: &'static str,
    function: F,
) -> JsResult<()>
where
    F: IntoJsFunc<'js, P> + 'js,
{
    let constructor = Function::new(ctx.clone(), function)?.with_constructor(true);
    ctx.globals().set(name, constructor)
}

/// Wrap `function` and set it on `object` under `name`; the wrapped
/// function is returned so callers can alias it (`attr`/`getAttribute`).
pub(super) fn set_function<'js, P, F>(
    ctx: &Ctx<'js>,
    object: &Object<'js>,
    name: &str,
    function: F,
) -> JsResult<Function<'js>>
where
    F: IntoJsFunc<'js, P> + 'js,
{
    let function = Function::new(ctx.clone(), function)?;
    object.set(name, function.clone())?;
    Ok(function)
}

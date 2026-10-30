//! Native ES modules: the host API surface of a realm.
//!
//! Realms install no host globals. Scripts import what they need —
//! `import { Crypto, Compression } from "langhuan:crypto"` — and a realm's
//! declared-module list is its capability list: importing an undeclared
//! module fails at link time. QuickJS resolves imports against the realm's
//! declared modules before any loader runs, so no module loader, filesystem,
//! or network is ever involved.
//!
//! A native module is a `ModuleDef` whose `declare` names its exports and
//! whose `evaluate` fills them on first import; the values are built with
//! the [`Namespace`] chain, [`constructor`], and [`set_function`] below.
//!
//! `langhuan:storage` is the one module that cannot fit this shape: its
//! backend is per-feed, and `ModuleDef` is static. Feed bootstrap wires the
//! backend in under an internal global, the module takes the global over on
//! first import, and bootstrap removes it if the source never imports it —
//! so no host global survives load either way. See `storage.rs`.

use rquickjs::function::IntoJsFunc;
use rquickjs::module::ModuleDef;
use rquickjs::{Ctx, Function, Module, Object, Result as JsResult};

/// A function namespace under construction, exported as one module member.
pub(super) struct Namespace<'js> {
    ctx: Ctx<'js>,
    object: Object<'js>,
}

impl<'js> Namespace<'js> {
    /// Start a namespace object.
    pub(super) fn new(ctx: &Ctx<'js>) -> JsResult<Self> {
        Ok(Self {
            ctx: ctx.clone(),
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

    /// Finish the namespace as an object.
    pub(super) fn object(self) -> Object<'js> {
        self.object
    }
}

/// Wrap a constructor function, callable with `new`; `function` builds the
/// instance object.
pub(super) fn constructor<'js, P, F>(ctx: &Ctx<'js>, function: F) -> JsResult<Function<'js>>
where
    F: IntoJsFunc<'js, P> + 'js,
{
    Ok(Function::new(ctx.clone(), function)?.with_constructor(true))
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

/// Declare the native module `name`; `D` fills its exports on first import.
pub(super) fn declare_module<'js, D>(ctx: &Ctx<'js>, name: &'static str) -> JsResult<()>
where
    D: ModuleDef,
{
    Module::declare_def::<D, _>(ctx.clone(), name).map(|_| ())
}

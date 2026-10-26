use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use rquickjs::function::Args;
use rquickjs::{
    CaughtError, Context, Ctx, Function, Object, Persistent, Runtime, Value as JsValue,
};
use serde_json::Value;

use super::html;
use crate::error::{Error, Result};

const QUICKJS_HEAP_LIMIT: usize = 32 * 1024 * 1024;
const QUICKJS_STACK_LIMIT: usize = 1024 * 1024;
const MAX_RESULT_BYTES: usize = 16 * 1024 * 1024;
const BOOTSTRAP_TIMEOUT: Duration = Duration::from_secs(5);

/// A QuickJS object together with the sandbox that owns its context.
pub(super) struct JsObject {
    inner: Persistent<Object<'static>>,
    // Keep the sandbox after the persistent value so the value is dropped first.
    sandbox: Sandbox,
}

// `rquickjs` makes Runtime and Context movable with its `parallel` feature, but
// does not propagate Send to Persistent values. JsObject is deliberately
// opaque and JsFeed keeps it behind a mutex, so its persistent value and cloned
// sandbox always move and execute as one exclusively accessed unit.
unsafe impl Send for JsObject {}

impl JsObject {
    pub(super) fn has_function(&mut self, path: &[&str]) -> Result<bool> {
        let Self { inner, sandbox } = self;
        sandbox.with_object(inner, |_, object| {
            let Some((owner, name)) = resolve_owner(object, path)? else {
                return Ok(false);
            };
            Ok(owner.get::<_, JsValue>(name)?.is_function())
        })
    }

    pub(super) fn call_json(&mut self, path: &[&str], arguments: &[Value]) -> Result<Value> {
        let arguments = serde_json::to_string(arguments)
            .map_err(|error| Error::javascript(error.to_string()))?;
        let Self { inner, sandbox } = self;
        let json = sandbox.with_object(inner, |ctx, object| {
            let (owner, name) = resolve_owner(object, path)?.ok_or_else(|| {
                rquickjs::Error::new_from_js_message(
                    "object",
                    "function",
                    format!("missing JavaScript method: {}", path.join(".")),
                )
            })?;
            let function: Function = owner.get(name)?;
            let parsed = ctx.json_parse(arguments)?;
            let arguments = parsed.into_array().ok_or_else(|| {
                rquickjs::Error::new_from_js_message("JSON", "Array", "arguments are not an array")
            })?;
            let mut call_arguments = Args::new(ctx.clone(), arguments.len());
            call_arguments.this(owner)?;
            for argument in arguments.iter::<JsValue>() {
                call_arguments.push_arg(argument?)?;
            }
            let result: JsValue = function.call_arg(call_arguments)?;
            ctx.json_stringify(result)?
                .ok_or_else(|| {
                    rquickjs::Error::new_from_js_message(
                        "JavaScript value",
                        "JSON",
                        "method returned undefined",
                    )
                })?
                .to_string()
        })?;
        sandbox.check_result_size(&json)?;
        serde_json::from_str(&json)
            .map_err(|error| Error::javascript(format!("invalid JavaScript result: {error}")))
    }
}

fn resolve_owner<'js>(
    mut object: Object<'js>,
    path: &[&str],
) -> rquickjs::Result<Option<(Object<'js>, String)>> {
    let Some((name, parents)) = path.split_last() else {
        return Ok(None);
    };
    for parent in parents {
        let value: JsValue = object.get(*parent)?;
        let Some(next) = value.into_object() else {
            return Ok(None);
        };
        object = next;
    }
    Ok(Some((object, (*name).to_owned())))
}

/// A persistent native QuickJS runtime with no host I/O capabilities.
///
/// The only Rust callback exposed to scripts is the bounded, read-only HTML
/// parser. No filesystem, sockets, process, environment, module loader, or
/// browser networking APIs are installed. Feed HTTP remains represented as
/// data and is executed by Rust after policy validation.
#[derive(Clone)]
pub(super) struct Sandbox {
    context: Context,
    // Keep the runtime after the context so the context is dropped first.
    _runtime: Runtime,
    deadline: Arc<Mutex<Instant>>,
    timeout: Duration,
}

impl Sandbox {
    pub(super) fn new(timeout: Duration) -> Result<Self> {
        let runtime = Runtime::new().map_err(sandbox_error)?;
        runtime.set_memory_limit(QUICKJS_HEAP_LIMIT);
        runtime.set_max_stack_size(QUICKJS_STACK_LIMIT);

        let deadline = Arc::new(Mutex::new(Instant::now() + BOOTSTRAP_TIMEOUT));
        let interrupt_deadline = Arc::clone(&deadline);
        runtime.set_interrupt_handler(Some(Box::new(move || {
            interrupt_deadline
                .lock()
                .map_or(true, |deadline| Instant::now() >= *deadline)
        })));

        // Context::full installs standard ECMAScript intrinsics only. The
        // bounded HTML API below is the sandbox's sole native callback.
        let context = Context::full(&runtime).map_err(sandbox_error)?;
        context
            .with(|ctx| CaughtError::catch(&ctx, html::install(&ctx)).map_err(|e| e.to_string()))
            .map_err(sandbox_error)?;
        Ok(Self {
            context,
            _runtime: runtime,
            deadline,
            timeout,
        })
    }

    pub(super) fn eval_script(&mut self, code: &str) -> Result<()> {
        self.reset_deadline()?;
        self.context
            .with(|ctx| {
                CaughtError::catch(&ctx, ctx.eval::<(), _>(code)).map_err(|error| error.to_string())
            })
            .map_err(sandbox_error)
    }

    pub(super) fn eval_object(&mut self, code: &str) -> Result<JsObject> {
        self.reset_deadline()?;
        let sandbox = self.clone();
        self.context
            .with(move |ctx| {
                CaughtError::catch(&ctx, ctx.eval::<Object, _>(code))
                    .map(|object| JsObject {
                        inner: Persistent::save(&ctx, object),
                        sandbox,
                    })
                    .map_err(|error| error.to_string())
            })
            .map_err(sandbox_error)
    }

    pub(super) fn has_global(&mut self, name: &str) -> Result<bool> {
        self.reset_deadline()?;
        self.context
            .with(|ctx| {
                CaughtError::catch(&ctx, ctx.globals().contains_key(name))
                    .map_err(|error| error.to_string())
            })
            .map_err(sandbox_error)
    }

    fn with_object<T>(
        &mut self,
        object: &Persistent<Object<'static>>,
        callback: impl for<'js> FnOnce(Ctx<'js>, Object<'js>) -> rquickjs::Result<T>,
    ) -> Result<T> {
        self.reset_deadline()?;
        self.context
            .with(|ctx| {
                let object = object
                    .clone()
                    .restore(&ctx)
                    .map_err(|error| error.to_string())?;
                CaughtError::catch(&ctx, callback(ctx.clone(), object))
                    .map_err(|error| error.to_string())
            })
            .map_err(sandbox_error)
    }

    #[cfg(test)]
    pub(super) fn eval_json(&mut self, code: &str) -> Result<String> {
        self.reset_deadline()?;
        let output = self
            .context
            .with(|ctx| {
                CaughtError::catch(&ctx, ctx.eval::<String, _>(code))
                    .map_err(|error| error.to_string())
            })
            .map_err(sandbox_error)?;
        self.check_result_size(&output)?;
        Ok(output)
    }

    fn reset_deadline(&self) -> Result<()> {
        *self
            .deadline
            .lock()
            .map_err(|_| Error::javascript("native QuickJS deadline lock poisoned"))? =
            Instant::now() + self.timeout;
        Ok(())
    }

    fn check_result_size(&self, output: &str) -> Result<()> {
        if output.len() > MAX_RESULT_BYTES {
            return Err(Error::javascript(
                "native QuickJS result exceeds the size limit",
            ));
        }
        Ok(())
    }
}

fn sandbox_error(error: impl std::fmt::Display) -> Error {
    Error::javascript(format!("native QuickJS sandbox: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn evaluates_and_keeps_a_javascript_object() {
        let mut sandbox = Sandbox::new(Duration::from_secs(5)).unwrap();
        let mut object = sandbox
            .eval_object("({ value: 40, next() { this.value += 1; return this.value; } })")
            .unwrap();
        assert_eq!(
            object.call_json(&["next"], &[]).unwrap(),
            serde_json::json!(41)
        );
        assert_eq!(
            object.call_json(&["next"], &[]).unwrap(),
            serde_json::json!(42)
        );
    }

    #[test]
    fn has_no_host_capabilities() {
        let result = Sandbox::new(Duration::from_secs(5))
            .unwrap()
            .eval_json(
                r#"JSON.stringify({
                    fetch: typeof fetch,
                    process: typeof process,
                    require: typeof require,
                    wasi: typeof WASI,
                    webAssembly: typeof WebAssembly,
                    deno: typeof Deno,
                    bun: typeof Bun,
                    std: typeof std,
                    os: typeof os,
                })"#,
            )
            .unwrap();
        assert_eq!(
            result,
            r#"{"fetch":"undefined","process":"undefined","require":"undefined","wasi":"undefined","webAssembly":"undefined","deno":"undefined","bun":"undefined","std":"undefined","os":"undefined"}"#
        );
    }

    #[test]
    fn enforces_heap_limit() {
        let error = Sandbox::new(Duration::from_secs(5))
            .unwrap()
            .eval_json(
                r#"(() => {
                  const values = [];
                  while (true) values.push("x".repeat(1024 * 1024));
                })()"#,
            )
            .unwrap_err();
        assert!(error.to_string().to_lowercase().contains("memory"));
    }

    #[test]
    fn enforces_stack_limit() {
        let error = Sandbox::new(Duration::from_secs(5))
            .unwrap()
            .eval_json("(function recurse() { return recurse(); })()")
            .unwrap_err();
        assert!(error.to_string().to_lowercase().contains("stack"));
    }

    #[test]
    fn supports_unicode_and_control_character_regexps() {
        let result = Sandbox::new(Duration::from_secs(5))
            .unwrap()
            .eval_json(
                r#"JSON.stringify({
                    invalid: /[;,\x00-\x1f\x7f]/.test("1"),
                    message: "登錄尚未完成：未檢測到起點登錄 Cookie",
                })"#,
            )
            .unwrap();
        assert!(result.contains("登錄尚未完成"));
    }

    #[test]
    fn rust_html_parser_supports_dom_operations() {
        let result = Sandbox::new(Duration::from_secs(5))
            .unwrap()
            .eval_json(
                r#"(() => {
                  const document = HTML.parse(`
                    <section id="results">
                      <article class="card featured">
                        <a href="/book/42.html"><span>Book &amp; One</span></a>
                      </article>
                      <article class="card"><a href="/other">Other</a></article>
                      <script>const fake = '<a href="/book/99.html">Fake</a>';</script>
                    </section>`);
                  const links = document.select(
                    '#results > article.card a[href*="/book/"][href$=".html"]'
                  );
                  return JSON.stringify({
                    count: links.length,
                    href: links.first().attr("href"),
                    text: links.first().text().trim(),
                    query: document.querySelector("article.featured").tagName,
                    parent: links.first().parent.tagName,
                  });
                })()"#,
            )
            .unwrap();
        assert_eq!(
            result,
            r#"{"count":1,"href":"/book/42.html","text":"Book & One","query":"article","parent":"article"}"#
        );
    }

    #[test]
    fn rust_html_parser_preserves_br_as_newline() {
        let result = Sandbox::new(Duration::from_secs(5))
            .unwrap()
            .eval_json(
                r##"JSON.stringify(HTML.parse("<div id='x'>one<br>two</div>").querySelector("#x").text())"##,
            )
            .unwrap();
        assert_eq!(result, r#""one\ntwo""#);
    }

    #[test]
    fn interrupts_infinite_loop() {
        let error = Sandbox::new(Duration::from_millis(50))
            .unwrap()
            .eval_json("while (true) {}")
            .unwrap_err();
        assert!(error.to_string().contains("interrupt"));
    }
}

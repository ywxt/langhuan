use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use rquickjs::{CaughtError, Context, Ctx, Object, Persistent, Runtime, Value as JsValue};

use super::bridge::{self, JsData};
use super::crypto;
use super::hostapi;
use super::html;
use crate::error::{Error, Result};

const QUICKJS_HEAP_LIMIT: usize = 32 * 1024 * 1024;
const QUICKJS_STACK_LIMIT: usize = 1024 * 1024;
const MAX_COMPUTE_PROGRAMS: usize = 8;
const MAX_COMPUTE_SOURCE_BYTES: usize = 4 * 1024 * 1024;
const BOOTSTRAP_TIMEOUT: Duration = Duration::from_secs(5);
#[cfg(test)]
const MAX_RESULT_BYTES: usize = 16 * 1024 * 1024;

/// A QuickJS object together with the sandbox that owns its context.
pub(super) struct JsObject {
    state: Mutex<JsObjectState>,
}

struct JsObjectState {
    inner: Persistent<Object<'static>>,
    // Keep the sandbox after the persistent value so the value is dropped first.
    sandbox: Sandbox,
}

// `rquickjs` makes Runtime and Context movable with its `parallel` feature, but
// does not propagate Send to Persistent values. JsObjectState is deliberately
// private and can only be reached through JsObject's mutex, so its persistent
// value and cloned sandbox always move and execute as one exclusive unit.
unsafe impl Send for JsObjectState {}

impl JsObject {
    pub(super) fn has_function(&self, path: &[&str]) -> Result<bool> {
        let mut state = self.lock_state()?;
        let JsObjectState { inner, sandbox } = &mut *state;
        sandbox.with_object(inner, |_, object| {
            let Some((owner, name)) = resolve_owner(object, path)? else {
                return Ok(false);
            };
            Ok(owner.get::<_, JsValue>(name)?.is_function())
        })
    }

    /// Run one exclusive unit of work inside the realm: build arguments as
    /// live values, call a method, and extract the result — all under the
    /// realm mutex, with no JSON round trip.
    ///
    /// The callback returns the outer `rquickjs::Result` for engine failures
    /// (including caught script exceptions) wrapping an inner `Result` for
    /// host-side extraction errors, so both surfaces stay distinguishable.
    pub(super) fn with_realm<T>(
        &self,
        callback: impl for<'js> FnOnce(
            Ctx<'js>,
            Object<'js>,
        ) -> rquickjs::Result<crate::error::Result<T>>,
    ) -> Result<T> {
        let mut state = self.lock_state()?;
        let JsObjectState { inner, sandbox } = &mut *state;
        sandbox
            .with_object(inner, |ctx, object| callback(ctx.clone(), object))
            .map_err(sandbox_error)?
    }

    fn lock_state(&self) -> Result<std::sync::MutexGuard<'_, JsObjectState>> {
        self.state
            .lock()
            .map_err(|_| Error::javascript("QuickJS object lock poisoned"))
    }
}

pub(super) fn resolve_owner<'js>(
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
        Self::new_with_profile(timeout, SandboxProfile::Feed)
    }

    fn new_compute(timeout: Duration) -> Result<Self> {
        Self::new_with_profile(timeout, SandboxProfile::Compute)
    }

    fn new_with_profile(timeout: Duration, profile: SandboxProfile) -> Result<Self> {
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

        // Both profiles need the Eval intrinsic because Rust's Ctx::eval uses
        // it to load source. The feed profile removes every JavaScript-visible
        // dynamic compiler below, before any untrusted feed source runs.
        let context = Context::full(&runtime).map_err(sandbox_error)?;
        // Pure host utilities (TextDecoder/TextEncoder/Bytes) are installed in
        // both profiles: they leak no capabilities, and compute programs may
        // need them just like feed reducers do.
        context
            .with(|ctx| {
                CaughtError::catch(&ctx, hostapi::install(&ctx)).map_err(|e| e.to_string())
            })
            .map_err(sandbox_error)?;
        context
            .with(|ctx| {
                CaughtError::catch(&ctx, crypto::install(&ctx)).map_err(|e| e.to_string())
            })
            .map_err(sandbox_error)?;
        if matches!(profile, SandboxProfile::Feed) {
            context
                .with(|ctx| {
                    CaughtError::catch(&ctx, html::install(&ctx)).map_err(|e| e.to_string())
                })
                .map_err(sandbox_error)?;
        }
        if matches!(profile, SandboxProfile::Feed) {
            context
                .with(|ctx| {
                    CaughtError::catch(
                        &ctx,
                        ctx.eval::<(), _>(
                            r#"
                            (() => {
                              const prototypes = [
                                Object.getPrototypeOf(function() {}),
                                Object.getPrototypeOf(async function() {}),
                                Object.getPrototypeOf(function*() {}),
                                Object.getPrototypeOf(async function*() {}),
                              ];
                              for (const prototype of prototypes) {
                                Object.defineProperty(prototype, "constructor", {
                                  value: undefined,
                                  writable: false,
                                  configurable: false,
                                });
                              }
                              Object.defineProperty(globalThis, "eval", {
                                value: undefined,
                                writable: false,
                                configurable: false,
                              });
                              Object.defineProperty(globalThis, "Function", {
                                value: undefined,
                                writable: false,
                                configurable: false,
                              });
                            })();
                            "#,
                        ),
                    )
                    .map_err(|error| error.to_string())
                })
                .map_err(sandbox_error)?;
        }
        Ok(Self {
            context,
            _runtime: runtime,
            deadline,
            timeout,
        })
    }

    /// Execute website-provided programs in a fresh, capability-free realm.
    ///
    /// The only value crossing into the realm is the [`JsData`] input,
    /// materialized as a live JavaScript value (bytes become `Uint8Array`);
    /// the only value crossing out is the final program's result, deep-copied
    /// back as [`JsData`]. The realm is destroyed when this function returns
    /// and never shares globals with a feed.
    pub(super) fn compute(programs: &[String], input: &JsData, timeout: Duration) -> Result<JsData> {
        if programs.is_empty() || programs.len() > MAX_COMPUTE_PROGRAMS {
            return Err(Error::javascript(format!(
                "compute requires 1..={MAX_COMPUTE_PROGRAMS} programs"
            )));
        }
        let source_bytes = programs.iter().map(String::len).sum::<usize>();
        if source_bytes > MAX_COMPUTE_SOURCE_BYTES {
            return Err(Error::javascript("compute source exceeds the size limit"));
        }
        if input.measure() > bridge::MAX_BRIDGE_BYTES {
            return Err(Error::javascript("compute input exceeds the size limit"));
        }

        let sandbox = Self::new_compute(timeout)?;
        sandbox.reset_deadline()?;
        let output: crate::error::Result<JsData> = sandbox.context.with(|ctx| {
            let outcome: rquickjs::Result<crate::error::Result<JsData>> = (|| {
                let input_value = bridge::jsdata_to_js(&ctx, input)?;
                ctx.globals().set("input", input_value)?;
                let mut result = JsValue::new_undefined(ctx.clone());
                for program in programs {
                    result = ctx.eval::<JsValue, _>(program.as_bytes())?;
                }
                Ok(bridge::js_to_jsdata(&result))
            })();
            match CaughtError::catch(&ctx, outcome) {
                Ok(result) => result,
                Err(error) => {
                    Err(Error::javascript(format!("native QuickJS sandbox: {error}")))
                }
            }
        });
        let data = output?;
        if matches!(data, JsData::Undefined) {
            return Err(Error::javascript("compute returned undefined"));
        }
        if data.measure() > bridge::MAX_BRIDGE_BYTES {
            return Err(Error::javascript("compute result exceeds the size limit"));
        }
        Ok(data)
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
                        state: Mutex::new(JsObjectState {
                            inner: Persistent::save(&ctx, object),
                            sandbox,
                        }),
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

    #[cfg(test)]
    fn check_result_size(&self, output: &str) -> Result<()> {
        if output.len() > MAX_RESULT_BYTES {
            return Err(Error::javascript(
                "native QuickJS result exceeds the size limit",
            ));
        }
        Ok(())
    }
}

/// Test-only JSON round-trip helper exercising the same bridge the runtime
/// uses, so JSON-shaped calls stay covered while production code goes through
/// `with_realm` directly.
#[cfg(test)]
impl JsObject {
    fn call_json(
        &self,
        path: &[&str],
        arguments: &[serde_json::Value],
    ) -> Result<serde_json::Value> {
        self.with_realm(|ctx, object| {
            let (owner, name) = resolve_owner(object, path)?.ok_or_else(|| {
                rquickjs::Error::new_from_js_message(
                    "object",
                    "function",
                    format!("missing JavaScript method: {}", path.join(".")),
                )
            })?;
            let function: rquickjs::Function = owner.get(name)?;
            let mut call_arguments =
                rquickjs::function::Args::new(ctx.clone(), arguments.len());
            call_arguments.this(owner)?;
            for argument in arguments {
                call_arguments.push_arg(bridge::json_to_js(&ctx, argument)?)?;
            }
            let result: JsValue = function.call_arg(call_arguments)?;
            let json = bridge::js_to_json(&ctx, &result)
                .map_err(|error| {
                    rquickjs::Error::new_from_js_message("value", "JSON", error.to_string())
                })?
                .ok_or_else(|| {
                    rquickjs::Error::new_from_js_message(
                        "value",
                        "JSON",
                        "method returned undefined",
                    )
                })?;
            Ok(Ok(json))
        })
    }
}

#[derive(Clone, Copy)]
enum SandboxProfile {
    Feed,
    Compute,
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
        let object = sandbox
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
    fn hostapi_is_available_in_the_feed_realm() {
        let mut sandbox = Sandbox::new(Duration::from_secs(5)).unwrap();
        let result = sandbox
            .eval_json(
                r#"JSON.stringify({
                    decoder: typeof TextDecoder,
                    encoder: typeof TextEncoder,
                    bytes: typeof Bytes,
                })"#,
            )
            .unwrap();
        assert_eq!(
            result,
            r#"{"decoder":"function","encoder":"function","bytes":"object"}"#
        );
    }

    #[test]
    fn hostapi_decodes_encodings_and_converts_bytes() {
        let mut sandbox = Sandbox::new(Duration::from_secs(5)).unwrap();
        let result = sandbox
            .eval_json(
                r#"JSON.stringify({
                    gbk: new TextDecoder("gbk").decode(new Uint8Array([0xC4, 0xE3, 0xBA, 0xC3])),
                    utf8: new TextDecoder().decode(new TextEncoder().encode("你好")),
                    bom: new TextDecoder().decode(new TextEncoder().encode("x")).length,
                    b64: Bytes.toBase64(new TextEncoder().encode("foobar")),
                    hex: Bytes.toHex(Bytes.fromBase64("Zm9vYmFy")),
                    padded: Bytes.fromBase64("Zg==").length,
                    urlSafe: Bytes.toBase64(new Uint8Array([0xFB, 0xFF, 0xBF]), { urlSafe: true }),
                })"#,
            )
            .unwrap();
        assert_eq!(
            result,
            r#"{"gbk":"你好","utf8":"你好","bom":1,"b64":"Zm9vYmFy","hex":"666f6f626172","padded":1,"urlSafe":"-_-_"}"#
        );
    }

    #[test]
    fn crypto_and_compression_work_from_javascript() {
        let mut sandbox = Sandbox::new(Duration::from_secs(5)).unwrap();
        let result = sandbox
            .eval_json(
                r#"JSON.stringify({
                    md5: Bytes.toHex(Crypto.md5(new TextEncoder().encode("abc"))),
                    hmac: Bytes.toHex(Crypto.hmac("sha256", new TextEncoder().encode("Jefe"),
                        new TextEncoder().encode("what do ya want for nothing?"))),
                    gcm: Bytes.toHex(Crypto.aes({
                        op: "encrypt",
                        mode: "gcm",
                        key: Bytes.fromHex("7fddb57453c241d03efbed3ac44e371c"),
                        iv: Bytes.fromHex("ee283a3fc75575e33efd4887"),
                        data: Bytes.fromHex("d5de42b461646c255c87bd2962d3b9a2"),
                    })),
                    gunzip: new TextDecoder().decode(
                        Compression.gunzip(Compression.gzip(new TextEncoder().encode("packed")))),
                    random: Crypto.randomBytes(32).length,
                })"#,
            )
            .unwrap();
        assert_eq!(
            result,
            concat!(
                r#"{"md5":"900150983cd24fb0d6963f7d28e17f72","#,
                r#""hmac":"5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843","#,
                r#""gcm":"2ccda4a5415cb91e135c2a0f78c9b2fdb36d1df9b9d5e596f83e8b7f52971cb3","#,
                r#""gunzip":"packed","random":32}"#
            )
        );
    }

    #[test]
    fn compute_realm_has_the_host_byte_utilities() {
        let result = Sandbox::compute(
            &[r#"JSON.stringify({
                    decoder: typeof TextDecoder,
                    encoder: typeof TextEncoder,
                    bytes: typeof Bytes,
                })"#
            .to_owned()],
            &JsData::Null,
            Duration::from_secs(5),
        )
        .unwrap();
        assert_eq!(
            result,
            JsData::Str(
                r#"{"decoder":"function","encoder":"function","bytes":"object"}"#.to_owned()
            )
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
    fn feed_realm_disables_dynamic_code_compilation() {
        let result = Sandbox::new(Duration::from_secs(5))
            .unwrap()
            .eval_json(
                r#"JSON.stringify({
                    evalType: typeof eval,
                    functionType: typeof Function,
                    constructorCompile: (() => {
                        try {
                            return (() => {}).constructor("return 1")();
                        } catch (_) {
                            return "blocked";
                        }
                    })(),
                })"#,
            )
            .unwrap();
        assert_eq!(
            result,
            r#"{"evalType":"undefined","functionType":"undefined","constructorCompile":"blocked"}"#
        );
    }

    #[test]
    fn compute_uses_a_disposable_capability_free_realm() {
        let result = Sandbox::compute(
            &[
                "globalThis.remoteValue = input.value * 2;".to_owned(),
                r#"({
                    value: globalThis.remoteValue,
                    evalType: typeof eval,
                    htmlType: typeof HTML,
                    fetchType: typeof fetch,
                    processType: typeof process,
                    authType: typeof auth,
                    requireType: typeof require,
                    stdType: typeof std,
                    osType: typeof os,
                    webAssemblyType: typeof WebAssembly,
                })"#
                .to_owned(),
            ],
            &JsData::from_json(&serde_json::json!({ "value": 21 })),
            Duration::from_secs(5),
        )
        .unwrap();
        assert_eq!(
            result.into_json(),
            serde_json::json!({
                "value": 42,
                "evalType": "function",
                "htmlType": "undefined",
                "fetchType": "undefined",
                "processType": "undefined",
                "authType": "undefined",
                "requireType": "undefined",
                "stdType": "undefined",
                "osType": "undefined",
                "webAssemblyType": "undefined",
            })
        );

        let next = Sandbox::compute(
            &["typeof globalThis.remoteValue".to_owned()],
            &JsData::Null,
            Duration::from_secs(5),
        )
        .unwrap();
        assert_eq!(next.into_json(), serde_json::json!("undefined"));
    }

    #[test]
    fn compute_input_and_result_can_carry_bytes() {
        let result = Sandbox::compute(
            &[
                "globalThis.kept = input.bytes;".to_owned(),
                r#"({ length: input.bytes.length, first: input.bytes[0], kind: Object.prototype.toString.call(globalThis.kept) })"#
                    .to_owned(),
            ],
            &JsData::Obj(vec![(
                "bytes".to_owned(),
                JsData::Bytes(bytes::Bytes::from_static(&[7, 8, 9])),
            )]),
            Duration::from_secs(5),
        )
        .unwrap();
        assert_eq!(
            result.into_json(),
            serde_json::json!({
                "length": 3,
                "first": 7,
                "kind": "[object Uint8Array]",
            })
        );

        let echoed = Sandbox::compute(
            &["input.bytes".to_owned()],
            &JsData::Obj(vec![(
                "bytes".to_owned(),
                JsData::Bytes(bytes::Bytes::from_static(&[250, 251])),
            )]),
            Duration::from_secs(5),
        )
        .unwrap();
        assert_eq!(
            echoed,
            JsData::Bytes(bytes::Bytes::from_static(&[250, 251]))
        );
    }

    #[test]
    fn compute_rejects_undefined_results() {
        let error = Sandbox::compute(
            &["globalThis.nothing = 1; undefined".to_owned()],
            &JsData::Null,
            Duration::from_secs(5),
        )
        .unwrap_err();
        assert!(error.to_string().contains("undefined"));
    }

    #[test]
    fn compute_interrupts_infinite_loop() {
        let error = Sandbox::compute(
            &["while (true) {}".to_owned()],
            &JsData::Null,
            Duration::from_millis(50),
        )
        .unwrap_err();
        assert!(error.to_string().contains("interrupt"));
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

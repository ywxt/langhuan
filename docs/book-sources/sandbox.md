# Sandbox capabilities and limits

Book sources are untrusted input. Langhuan runs each source in native QuickJS,
but the security boundary is defined by the host capabilities exposed to that
runtime—not by JavaScript syntax alone.

## Security model

Each loaded source owns one QuickJS runtime and context. Its ES module is
evaluated once, the default-exported Feed object is retained, and calls on that
object are serialized.

The feed realm has no:

- filesystem or path API;
- sockets, `fetch`, `XMLHttpRequest`, or WebSocket;
- process, shell, FFI, dynamic native library, or environment access;
- unrestricted module loader or dynamic `import()`;
- DOM/browser networking implementation;
- direct application database or authentication object access.

Imports resolve only to host modules declared for that realm. An unknown
module fails while linking the source.

HTTP is deliberately outside the sandbox. A reducer returns a plain request
descriptor; Rust checks its target against metadata and performs the request.

## Feed and compute realms

There are two profiles:

| Capability | Feed realm | Compute realm |
| --- | :---: | :---: |
| Retained between operations | Yes | No |
| Source metadata and reducer object | Yes | No |
| `langhuan:encoding` | Yes | Yes |
| `langhuan:crypto` | Yes | Yes |
| `langhuan:protobuf` | Yes | Yes |
| `langhuan:html` | Yes | No |
| `langhuan:storage` | When host backend exists | No |
| Authentication/session state | Only the bounded `event.auth` value | No |
| Network or system access | No | No |

The persistent feed realm disables JavaScript-visible `eval`, `Function`, and
function constructors before untrusted source code runs. This prevents a
source from treating downloaded text as executable code in its privileged,
stateful realm.

A `compute` step is the explicit exception for websites that ship required
JavaScript. Rust creates a fresh realm, evaluates only the listed ES-module
programs, supplies one copied `input` value, copies out the final default
export, and destroys the realm. Dynamic compilation can exist inside this
disposable realm, but it still has no HTML, storage, source object, credentials,
network, filesystem, or native bridge.

## Compute example

```js
return {
  type: "compute",
  programs: [
    downloadedProgram,
    "export default decrypt(input.payload, input.key);",
  ],
  input: { payload: encryptedBytes, key: chapterKey },
  next_state: { stage: "decrypted" },
};
```

Programs run in order and share globals within that one compute realm. The
last program's `export default` becomes `event.compute` on the next reducer
call. Programs may import the three pure compute modules.

Pass only the minimum data needed by the algorithm. Never place the complete
authentication object, all cookies, or persistent source state in `input`.

## WebView is not a sandbox escape

A `webview` step delegates one URL and source-selected User-Agent to a platform
browser controlled by the application. The user interacts with it. The source
does not receive a WebView object or JavaScript bridge; it receives a snapshot
containing the final URL, HTML, and cookies after the host closes the page.

```js
return {
  type: "webview",
  url: `${meta.base_url}/verify`,
  title: "Complete verification",
  user_agent: USER_AGENT,
  next_state: { stage: "verified" },
};
```

Use this only for a genuinely human gate. If the user cancels or the platform
has no WebView host, the operation fails with an authentication-required error.
The operation can remain parked while the user interacts.

## Resource limits

| Resource | Limit |
| --- | ---: |
| QuickJS heap per realm | 32 MiB |
| QuickJS stack | 1 MiB |
| Feed reducer execution deadline per call | 30 seconds |
| Compute execution deadline | 5 seconds |
| Bootstrap execution deadline | 5 seconds |
| Request/compute/WebView steps per operation | 8 |
| Compute programs per step | 1–8 |
| Total compute source | 4 MiB |
| Compute input or result bridge value | 16 MiB |
| Completed `items`/`value` bridge value | 16 MiB |
| HTML parser input | 4 MiB |
| Decompressed output | 32 MiB |
| Protobuf message | 32 MiB |
| `Crypto.randomBytes` output | 1 MiB |
| WebView/login User-Agent | 512 bytes |
| Storage key | 1–256 UTF-8 bytes |
| Cached helper responses | 8 per source, 1 MiB each |
| HTTP attempt timeout | 30 seconds |

A transient HTTP failure can be retried three times after the initial attempt,
with bounded backoff. These retries happen in the host and do not consume
additional reducer steps.

Limits are independent. For example, a 4 MiB compute program still needs to
fit in the realm's 32 MiB heap during compilation and execution.

## Value boundaries

Values carried by `next_state` stay inside the feed realm and can retain normal
JavaScript identity. `event.compute` is deep-copied from the disposable realm
and supports:

- strings, booleans, finite numbers, `null`, and `undefined`;
- arrays and plain objects;
- `Uint8Array` byte values.

Functions and host objects cannot cross realms. Cyclic or oversized values are
rejected.

Final `complete.items` and `complete.value` enter the Rust data model and must
be JSON-compatible. Decode bytes to text or encode them as base64/hex before
completion.

## Ambient compatibility helpers

QuickJS is not a browser. The feed realm provides only small, inert helpers
needed by common site code:

- `atob` and `btoa`;
- `window` and `self` aliases for `globalThis`;
- `navigator.userAgent` set to `Langhuan QuickJS`;
- no-op `console` methods;
- `performance.now()` backed by the current time;
- timer shims that do not schedule asynchronous work;
- frozen `meta` and frozen `FeedError` objects.

Top-level `await` is unsupported. Reducers and login hooks must finish
synchronously.

## What the sandbox does not promise

- It does not make a malicious source trustworthy. A permitted request can
  still send data to a domain the source declared.
- It does not prove a website's downloaded compute program is benign; it
  limits what that program can reach and how many resources it can consume.
- It does not protect credentials voluntarily returned by `login.parse` from
  the same source's `patchRequest`. Import and authenticate only trusted
  sources.
- It does not guarantee a third-party website will remain compatible.

Review source metadata and code before importing it. Keep domain allowlists as
narrow as possible, persist the minimum authentication data, and prefer native
modules over downloaded JavaScript whenever the algorithm is known.

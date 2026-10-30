# Book Source Guide

Langhuan book sources are ES modules executed by an isolated native QuickJS
runtime. A source describes requests as plain data; it cannot open sockets,
files, processes, environment variables, or native APIs — host utilities are
imported from the declared `langhuan:*` modules, never installed as globals.

Current examples:

- [`biquge-tw.js`](biquge-tw.js) — ordinary HTML pages.
- [`qidian.js`](qidian.js) — login, additional API requests, and purchased VIP
  chapter decryption using the site's official JavaScript bundle.
- [`fanqie.js`](fanqie.js) — server-rendered pages whose text is font-obfuscated
  (decoded through an embedded glyph table pinned to the served font), with
  keyword search via the site's JSON API (POST with query-string parameters;
  plain GETs are risk-control challenged) and an interactive WebView
  verification fallback for when the search endpoint is risk-gated. The
  source also persists WebView login cookies for chapters that require a
  logged-in account and verifies them against the reader user endpoint.
  Chapters gated behind the site's SVIP entitlement serve only a preview on
  the web — an entitlement wall rather than anti-crawling — which the source
  reports as an explicit sign-in or entitlement error instead of returning
  partial content.

There is no legacy runtime compatibility. Schema 4 sources must use `.js`,
must be ES modules, and must `export default` their Feed object. Assigning
`globalThis.feed` is not supported. Schema 3 sources fail to load with a
migration hint: response bodies are now `Uint8Array` values that must be
decoded with `TextDecoder` before use as text.

## Metadata

Every file starts with a comment header:

```js
// ==Feed==
// @id           example
// @name         Example Source
// @version      3.0.0
// @author       You
// @description  Example schema-4 source
// @base_url     https://example.com
// @access_domain example.com
// @access_domain *.static.example.com
// @schema_version 4
// ==/Feed==
```

`id`, `name`, `version`, `base_url`, and `schema_version` are required. Declare
every hostname the Rust host may contact with one `access_domain` line. A
leftmost wildcard such as `*.static.example.com` permits subdomains but not the
root `static.example.com`; other wildcard positions are rejected. Domain checks
apply to every request descriptor returned by the source.

The runtime exposes the parsed header as the frozen global `meta` object.

## Host modules

The runtime installs no host globals. Every host-provided API lives in a
native module that a source imports explicitly, and a realm's declared-module
list is its capability list — importing an undeclared module fails at link
time, before any code runs:

| Module               | Exports                                      | Feed realm | Compute realms |
| -------------------- | -------------------------------------------- | :--------: | :------------: |
| `langhuan:encoding`  | `TextDecoder`, `TextEncoder`, `Bytes`        |     ✓      |       ✓        |
| `langhuan:crypto`    | `Crypto`, `Compression`                      |     ✓      |       ✓        |
| `langhuan:html`      | `HTML`                                       |     ✓      |       —        |
| `langhuan:protobuf`  | `Protobuf`                                   |     ✓      |       ✓        |
| `langhuan:storage`   | `storage`                                    |    ✓ \*    |       —        |

`langhuan:storage` is declared only when the host application installed a
storage backend for the feed; without one the import fails at link time like
any undeclared module.

Host modules are native values, not parsed JSON: importing one and calling it
never serializes arguments or results. The modules are evaluated lazily on
first import.

## Export contract

The source is an ES module. Module scope keeps helpers private, so no IIFE
is needed; `export default` is the handler table:

```js
import { TextDecoder } from "langhuan:encoding";
import { HTML } from "langhuan:html";

function search(event) { /* reducer */ }
function bookInfo(event) { /* reducer */ }
function chapters(event) { /* reducer */ }
function paragraphs(event) { /* reducer */ }

export default { search, bookInfo, chapters, paragraphs };
```

The four handlers are required. `login` is optional:

```js
export default { search, bookInfo, chapters, paragraphs, login };
```

The module is evaluated once when the source is loaded. Its default export
remains in that feed's native QuickJS context and all later operations call
the retained methods. Do not mutate globals to register handlers.

## Reducer model

Each operation is a synchronous reducer. It receives an event and returns one
of five steps:

```ts
type Event = {
  operation: "search" | "book_info" | "chapters" | "paragraphs" | "auth_status";
  input: object;
  cursor: unknown;
  state: unknown;
  response?: {
    status: number;
    headers: [string, string][];
    body: Uint8Array;
    url: string;
  };
  compute?: unknown;
  auth?: object;
  webview?: {
    current_url: string;
    html: string;
    cookies: { name: string; value: string; domain?: string }[];
  };
};

type Step =
  | { type: "request"; request: Request; next_state?: unknown; cache_key?: string }
  | { type: "compute"; programs: string[]; input?: unknown; next_state?: unknown }
  | { type: "webview"; url: string; user_agent: string; title?: string; next_state?: unknown }
  | { type: "complete"; items?: unknown[]; value?: unknown; next_cursor?: unknown }
  | { type: "fail"; code: string; message: string };
```

On the first call, `state`, `response`, and `compute` are `undefined` (test
them with loose equality: `event.state == null`, which also matches `null`).
Return a request. Rust validates and performs it, then calls the same reducer
with the response and the provided `next_state`. This can repeat for multi-step
flows such as Qidian:

```text
chapter HTML -> chapter API -> official decryptor bundle -> isolated compute -> complete
```

The script never performs HTTP itself.

`next_state` is carried between rounds as a live JavaScript value, not a JSON
copy: `Date` instances, `Uint8Array` buffers, `undefined` properties, and
closures survive unchanged. The same applies to the `compute` result returned as
`event.compute`. Only the values inside a final `complete` step (`items`,
`value`) are materialized for the host and must be plain JSON-compatible data.

### Request descriptor

```js
{
  url: "https://example.com/search",
  method: "GET",                 // defaults to GET
  headers: { Accept: "text/html" },
  params: { q: "keyword" },      // URL query parameters
  // body: optional string or Uint8Array, omitted for no body
}
```

Rust enforces the domain allowlist, response-size limits, retry policy, trace
redaction, and at most eight internal request/compute/webview steps per
operation.
`cache_key` enables the small per-feed response cache and single-flight
behavior for immutable helper assets such as a decryptor bundle.
Only use it when both the URL and content are immutable. For a script URL
selected by the current page, discover the URL for each operation and omit
`cache_key` so an upstream rollout is observed immediately.

### Isolated computation

The persistent Feed realm does not expose `eval`, `Function`, or function
constructors. A source that must run JavaScript returned by a website can
request an isolated computation instead:

```js
return {
  type: "compute",
  programs: [
    bodyText(event.response),     // site-provided code, decoded to a string
    "export default decrypt(input.encrypted, input.key);",
  ],
  input: { encrypted, key },
  next_state: { stage: "decrypted" },
};
```

Each program is evaluated as an ES module, so site code can import the
realm's declared host modules (`langhuan:encoding`, `langhuan:crypto`).
Programs run in order and share the realm's globals, and the final program's
`export default` value comes back as `event.compute`.

Rust creates a fresh QuickJS realm for each compute step, declares no
`langhuan:html` module, no native callbacks, network API, module loader,
filesystem, process, or environment access, and evaluates `programs` in
order. The `input` value enters the realm as a live JavaScript value — it
and the result may include strings, numbers, booleans, arrays, plain
objects, `null`/`undefined`, and `Uint8Array` bytes.
The realm is destroyed immediately afterwards. It has independent heap, stack,
execution-time, source-size, program-count, and result-size limits.

Do not pass complete authentication objects to compute. Provide only the
minimum scalar inputs required by the website algorithm.

### Interactive WebView verification

Some gates cannot be cleared from a script at all: anti-bot sliders, device
checks, or consent walls that only a human in a real browser satisfies. When a
reducer hits one, it returns a `webview` step:

```js
return {
  type: "webview",
  url: `${meta.base_url}/library`,   // page that triggers the challenge
  title: "番茄小說驗證",               // optional UI title
  user_agent: USER_AGENT,            // applied before the first navigation
  next_state: { stage: "verified" },
};
```

The host applies `user_agent` before the first navigation and opens the page
in an embedded platform WebView. After the user completes the interaction,
the page snapshot — final URL, HTML, collected cookies, and the same
script-selected User-Agent — comes back as `event.webview` with `next_state`,
letting the reducer continue:

```js
if (event.webview != null) {
  const cookies = event.webview.cookies
    .filter((c) => c.domain?.endsWith("example.com"))
    .map((c) => `${c.name}=${c.value}`)
    .join("; ");
  return {
    type: "request",
    request: {
      url: "...",
      method: "POST",
      headers: { Cookie: cookies, "User-Agent": USER_AGENT },
    },
    next_state: { stage: "results" },
  };
}
```

Replays should reuse the same `USER_AGENT` supplied by the `webview` step:
cookie-based clearances (for example Cloudflare's `cf_clearance`) can be
issued for that User-Agent and rejected under a different string. The host
does not return the value in `event.webview`, because the source already owns
it.

Notes:

- The operation parks while the user interacts — it can take minutes; there
  is no timeout, and the search results arrive when the user finishes.
- If the user abandons the page, the operation fails with `auth_required`.
  The same error surfaces when the environment provides no WebView host.
- The step counts toward the eight-step internal limit, so a script cannot
  loop verification; gate → verify → retry counts as three steps.
- Use it only for human-only gates. Preflighting it on every operation
  would train users to dismiss dialogs.
- Keep any harvested cookie string in module state (it persists for the
  feed's lifetime) and attach it to later requests, so verification happens
  once per session instead of once per operation. See `fanqie.js`.

### Operations

- `search`: `input.keyword`; return `items` and optional `next_cursor`.
- `bookInfo`: `input.bookId`; return one book in `value`.
- `chapters`: `input.bookId`; return chapter `items` and optional
  `next_cursor`.
- `paragraphs`: `input.bookId` and `input.chapterId`; return paragraph `items`
  and optional `next_cursor`.

Book objects require `id`, `title`, and `author`. Chapter objects require `id`
and `title`. Paragraphs use one of these forms:

```js
{ type: "title", text: "Chapter 1" }
{ type: "text", content: "Paragraph text" }
{ type: "image", url: "https://static.example.com/image.jpg", alt: null }
```

IDs must be stable and unique within an operation stream.

## Expected errors

Return a structured failure when the website is in an anticipated state:

```js
return FeedError.authRequired("Please sign in");
return FeedError.cfChallenge("Cloudflare challenge detected");
return FeedError.rateLimited("Try again later");
return FeedError.contentNotFound("Chapter is unavailable");
return FeedError.sourceUnavailable("Site is temporarily unavailable");
return FeedError.raise("unsupported_content", "Unsupported encryption");
```

Thrown JavaScript exceptions indicate source bugs and are reported as runtime
errors. See [`../error-handling.md`](../error-handling.md).

## HTML parsing

`langhuan:html` provides `HTML.parse()` through a bounded, read-only Rust
binding powered by `scraper`. It is declared only in the feed realm — compute
realms have no `langhuan:html` — and provides no filesystem, network, process,
environment, or other system access. Each input is limited to 4 MiB and returns
a document tree with CSS selection:

```js
import { HTML } from "langhuan:html";

const document = HTML.parse(bodyText(event.response));
const cards = document.select(".result-card");
const firstBook = document
  .select('a[href*="/book/"][href$=".html"]')
  .first();

const title = firstBook.text().trim();
const href = firstBook.attr("href");
```

Documents and elements support `select`, `querySelectorAll`, `querySelector`,
`text`/`textContent`, `attr`/`getAttribute`, `attrs`, `html`/`outer_html`,
`parent`, and `children`.
Selectors support tags, `#id`, `.class`, descendant and child combinators,
comma groups, and the attribute operators `=`, `*=`, `^=`, `$=`, `~=`, and
`|=`. A selection is array-like and adds `first()`.

## Byte and text utilities

QuickJS ships no `TextDecoder`, `TextEncoder`, or typed-array conversion
helpers, so `langhuan:encoding` provides them in both the feed realm and every
compute realm:

```js
import { TextDecoder, TextEncoder, Bytes } from "langhuan:encoding";

// Decode response bodies (and any other bytes) to text.
const DECODER = new TextDecoder("utf-8");          // or "gbk", "big5", "shift_jis", ...
function bodyText(response) {
  return DECODER.decode(response?.body);           // missing body -> ""
}

new TextDecoder("gbk", { fatal: true })            // throw on invalid bytes
new TextDecoder("utf-8", { ignoreBOM: true })      // keep a leading BOM

// Encode text to UTF-8 bytes (for a request body or a digest input).
const bytes = new TextEncoder().encode("你好");

// Base64 and hex conversions for Uint8Array values.
Bytes.toBase64(bytes);                             // "..." with padding
Bytes.toBase64(bytes, { urlSafe: true });          // "-" and "_" alphabet
Bytes.fromBase64("Zm9vYmFy");                      // -> Uint8Array
Bytes.fromBase64("Zm9v\nYmFy");                    // ASCII whitespace is skipped
Bytes.toHex(bytes);                                // lowercase hex
Bytes.fromHex("000fa5ff");                         // case-insensitive
```

Notes:

- `TextDecoder` accepts any WHATWG encoding label; a leading BOM of the
  requested encoding is removed unless `ignoreBOM` is set. Streaming decode
  (`{ stream: true }`) is not supported and throws.
- `new TextDecoder().decode()` with no argument returns the empty string, so
  `bodyText(null)` is safe.
- Returned values (`complete.items`/`value`) must be JSON-compatible: a
  `Uint8Array` there is rejected with guidance to decode it or encode it as
  base64/hex first.

## Cryptography and compression

Sites encrypt content with standard primitives, and reimplementing AES in a
sandboxed script would be both slow and wrong. `langhuan:crypto` provides
synchronous, pure-function namespaces in both the feed realm and every compute
realm:

```js
import { Crypto, Compression } from "langhuan:crypto";

Crypto.md5(data)                 // -> Uint8Array digest
Crypto.sha1(data)
Crypto.sha256(data)
Crypto.sha512(data)
Crypto.sm3(data)                 // GB/T 32905
Crypto.hmac("sha256", key, data) // algorithm: "md5"|"sha1"|"sha256"|"sha512"|"sm3"

Crypto.aes({
  op: "encrypt" | "decrypt",
  mode: "cbc" | "ecb" | "ctr" | "gcm",
  key,                          // Uint8Array, 16/24/32 bytes
  iv,                           // Uint8Array; required for cbc/ctr/gcm
  data,                         // Uint8Array
  padding: "pkcs7" | "none",    // cbc/ecb only; defaults to "pkcs7"
  aad,                          // Uint8Array, gcm only
})
// -> Uint8Array. GCM follows the WebCrypto convention: `data` on decrypt and
//    the returned value are ciphertext||tag (16-byte tag); `iv` is the nonce.

Crypto.simon(key, data)          // Simon128/256, ECB + PKCS#7; key: 32 bytes
Crypto.speck(key, data)          // Speck128/256, ECB + PKCS#7; key: 32 bytes

Crypto.randomBytes(length)      // -> Uint8Array from the system RNG

Compression.gzip(data)
Compression.gunzip(data)
Compression.deflateRaw(data)
Compression.inflateRaw(data)
```

Notes:

- Digests and HMACs return raw bytes; use `Bytes.toHex(...)` for hex output.
- `padding: "none"` requires the data length to be a multiple of 16 for cbc
  and ecb; `pkcs7` is the browser-compatible default.
- Decompression output is capped at 32 MiB, matching the sandbox heap limit.
- A common site pattern decrypts as
  `Crypto.aes({ op: "decrypt", mode: "cbc", key, iv, data: payload })` where
  `payload = base64(iv || ciphertext)` was split beforehand.
- `Crypto.simon`/`Crypto.speck` exist for one reason: app APIs that sign
  requests with ByteDance's x-argus / x-ladon scheme encrypt with these
  lightweight block ciphers. They are encrypt-only (signing never decrypts)
  and ECB is what the scheme uses; prefer `Crypto.aes` for anything else.

## Protobuf encoding

App-API request signing also encodes payloads in protobuf's wire format.
`langhuan:protobuf` provides a writer for the field shapes those payloads
use — varints and length-delimited strings, bytes, and submessages:

```js
import { Protobuf } from "langhuan:protobuf";

const writer = new Protobuf();
writer.varint(1, 150);          // field 1, wire type 0
writer.string(4, "1.6.1");      // field 4, UTF-8, length-delimited
writer.bytes(12, queryHash);    // field 12, raw bytes, length-delimited

const inner = new Protobuf();   // a submessage is nested bytes
inner.varint(1, 1);
writer.bytes(15, inner.finish());

const payload = writer.finish(); // -> Uint8Array
```

`varint` accepts non-negative integers up to 2^53; field numbers must be
1–536870911. `finish()` returns a copy, so a writer can be finished more
than once.

## Persistent storage

Feeds that register a device or negotiate a key need state that outlives a
single operation. `langhuan:storage` is a per-feed key-value store backed by
the host application — the module is only declared when the host installed a
backend, and every call is stamped with the feed's identifier, so a feed
sees only its own keys:

```js
import { storage } from "langhuan:storage";

const device = storage.get("device"); // stored JSON value, or undefined
storage.set("device", { device_id, install_id });
storage.delete("device");
```

The calls follow `localStorage` semantics: `get` returns the stored value or
`undefined`, `set` and `delete` return nothing and fail by throwing. Keys
are strings of 1–256 bytes; values are JSON (`undefined` is not a value, and
typed arrays must be encoded with `Bytes.toBase64` or `Bytes.toHex` first).
Values persist across operations and across feed reloads.

## Authentication

The optional `login` object contains:

```js
const login = {
  entry() {
    return {
      url: "https://example.com/login",
      title: "Sign in",
      user_agent: USER_AGENT,
    };
  },

  parse(page) {
    // page: { current_url, response (Uint8Array), response_headers, cookies }
    const session = page.cookies.find((cookie) => cookie.name === "session");
    if (!session) return FeedError.authRequired("Login is incomplete");
    return { cookie_header: `session=${session.value}` };
  },

  patchRequest(operation, request, auth) {
    request.headers ??= {};
    request.headers.Cookie = auth.cookie_header;
    request.headers["User-Agent"] = USER_AGENT;
    return request;
  },

  status(event) {
    if (event.state == null) {
      return {
        type: "request",
        request: { url: `${meta.base_url}/account`, method: "GET" },
        next_state: { requested: true },
      };
    }
    return { type: "complete", value: event.response.status === 200 };
  },
};
```

`entry`, `parse`, and `patchRequest` are required when `login` is present.
`status` is optional. Authentication data is persisted by the host and supplied
as `event.auth`; scripts should retain only the minimum cookies or tokens they
need. `patchRequest` receives the same operation descriptor used to construct
the reducer event: `{ operation, input }`. Request parameters such as `bookId`
and `chapterId` therefore have one canonical location under `input`; source
metadata remains available through the frozen global `meta` object.

`entry.user_agent` is required and the host applies it before navigating. It
does not read `navigator.userAgent` or return the value in `page`; the source
already owns it. Sessions captured in a browser can be bound to this
User-Agent, so `patchRequest` should replay the same source constant.

## Sandbox guarantees and limits

Every loaded feed owns one native QuickJS runtime and context. The source and
built-ins are evaluated once; the exported Feed object is retained. Reducer
calls are serialized per feed, and the execution deadline is reset for every
call:

- no filesystem, sockets, environment, subprocesses, module loader, dynamic
  `import()`, or host object references — imports resolve only against the
  realm's declared host modules;
- 32 MiB QuickJS heap and a 1 MiB QuickJS stack;
- a 30-second JavaScript deadline enforced by QuickJS's interrupt handler;
- a 16 MiB limit on materialized `complete` results;
- no state sharing between different feeds;
- reducer calls exchange live JavaScript values — `next_state` and compute
  results are never serialized, while `complete` payloads must be
  JSON-compatible data capped by the host;
- all network, authentication, caching, redirects, and domain checks remain in
  native Rust.

Browser globals are not generally available, and the host installs no
globals of its own — every host API must be imported from the modules listed
above. The runtime supplies only small pure ambient helpers needed by site
code: `atob`, `btoa`, `window/self` aliases, inert `console`, `performance.now`,
inert timer shims, and the frozen `meta` object. `navigator` deliberately
has no `webdriver` property so official anti-bot bundles do not mistake the
sandbox for browser automation.

## Ordinary and multi-request sources

The same reducer contract covers both kinds of site:

- An ordinary HTML source returns one `request`, decodes `response.body` with
  `TextDecoder` imported from `langhuan:encoding`, parses it, and returns
  `complete`.
- A site such as Qidian stores intermediate values in `next_state`, returns
  another request descriptor, evaluates pure site-provided decryption code in
  the guest, and finally returns `complete`.

Neither source receives an HTTP function. The difference is only the number of
request steps it describes.

# Book-source API Reference

This reference describes schema 4. All source files are JavaScript ES modules
and must default-export a Feed object.

## Metadata header

```js
// ==Feed==
// @id           org.example.books.demo
// @name         Demo Books
// @version      1.0.0
// @author       Example Author
// @description  Example source
// @base_url     https://books.example.org
// @access_domain books.example.org
// @access_domain *.cdn.example.org
// @schema_version 4
// ==/Feed==
```

| Field | Required | Value and behaviour |
| --- | :---: | --- |
| `id` | Yes | Non-empty globally stable source identifier. Use a reverse domain owned by the publisher. It namespaces registry records, auth, cache, and storage; changing it creates a different source. |
| `name` | Yes | Non-empty user-facing source name. |
| `version` | Yes | Non-empty source version string used to classify imports as install, upgrade, same version, or downgrade. The runtime does not interpret its format. |
| `author` | No | Publisher or maintainer displayed to the user. |
| `description` | No | Short user-facing description. |
| `base_url` | Yes | Non-empty primary site URL exposed as `meta.base_url`. It is not automatically added to the allowlist. |
| `access_domain` | No | One exact hostname or leftmost subdomain wildcard per line. Repeated lines form a deduplicated set. When at least one entry exists, requests to every other host—including an undeclared `base_url` host—are blocked. When no entry exists, domain filtering is disabled. |
| `schema_version` | Yes | Integer contract version. It must be `4` for this runtime. |

Exact IP hosts are accepted for development. Domain entries cannot contain a
scheme, port, path, credentials, or wildcard outside the leftmost `*.` label.
Unknown metadata keys are ignored for forward compatibility. For scalar keys,
the last occurrence wins; `access_domain` is the repeatable exception.

The frozen global `meta` contains `id`, `name`, `version`, `author`,
`description`, `base_url`, `access_domains`, and `schema_version`.

## Feed object

```ts
type Feed = {
  search(event: Event): Step;
  bookInfo(event: Event): Step;
  chapters(event: Event): Step;
  paragraphs(event: Event): Step;
  login?: Login;
};
```

All four content handlers are required synchronous functions.

| Handler | Parameter | Host behaviour |
| --- | --- | --- |
| `search` | One `Event` with `input.keyword` | Called page by page. A completion with `next_cursor` allows the host to request another page; without it the stream ends. |
| `bookInfo` | One `Event` with `input.bookId` | Must eventually complete with one valid `Book` in `value`. Pagination is not used. |
| `chapters` | One `Event` with `input.bookId` | May paginate with `next_cursor`; the host concatenates pages and rejects duplicate chapter IDs. |
| `paragraphs` | One `Event` with `input.bookId` and `input.chapterId` | May paginate with `next_cursor`; the host concatenates pages and assigns indices to paragraphs without explicit IDs. |
| `login` | Optional `Login` object | Enables interactive sign-in and authenticated request patching. Partial login implementations are rejected at source load. |

A handler must return a step object before the JavaScript deadline. Returning a
Promise or using top-level `await` is unsupported.

## Event

```ts
type Event = {
  operation: "search" | "book_info" | "chapters" | "paragraphs" | "auth_status";
  input: object;
  cursor: unknown;
  state: unknown;
  response?: Response;
  compute?: unknown;
  webview?: WebviewSnapshot;
  auth: object | null;
};
```

| Property | Value and behaviour |
| --- | --- |
| `operation` | Current operation name in snake case. It is stable for every round of one operation. |
| `input` | Host-created operation arguments. It is reconstructed from the original call and does not contain source metadata. |
| `cursor` | Value returned as the preceding page's `next_cursor`, or `null` on the first page. It is constant through all internal rounds used to produce that page. |
| `state` | The immediately preceding request/compute/WebView step's `next_state`. It is `undefined` on the first round and when no state was supplied. It remains a live value in the feed realm. |
| `response` | Present only on the round immediately after a request step. Mutually exclusive with `compute` and `webview`. |
| `compute` | Present only on the round immediately after a compute step. It is copied back into the feed realm and may contain `Uint8Array`. |
| `webview` | Present only on the round immediately after a WebView step. Mutually exclusive with `response` and `compute`. |
| `auth` | Persisted JSON value returned by `login.parse`, or `null`. It is supplied on every reducer round and is not automatically added to requests. |

Test first-round state with `event.state == null`, which handles both `null`
and `undefined`.

### Operation inputs

| Operation | Input fields | Meaning |
| --- | --- | --- |
| `search` | `keyword: string` | Exact user query passed to the source. The host does not trim or rewrite it for the source. |
| `book_info` | `bookId: string` | Source-owned stable book ID selected from search/bookshelf data. |
| `chapters` | `bookId: string` | Source-owned stable book ID. |
| `paragraphs` | `bookId: string`, `chapterId: string` | IDs of the requested book and chapter. |
| `auth_status` | No fields | Login-status probe invoked through `login.status`. |

### Response

```ts
type Response = {
  status: number;
  headers: [string, string][];
  body: Uint8Array;
  url: string;
};
```

| Field | Value and behaviour |
| --- | --- |
| `status` | HTTP status code as a number. Non-2xx responses are still delivered when the native HTTP layer did not classify them as transport errors. |
| `headers` | Response headers as ordered `[name, value]` pairs, preserving repeated names such as `set-cookie`. Header-name casing follows the native client. |
| `body` | Complete raw response bytes. It is never implicitly decoded. |
| `url` | Final URL after redirects. Use it when the site encodes identifiers or pagination in the redirected URL. |

### WebView snapshot

```ts
type WebviewSnapshot = {
  current_url: string;
  html: string;
  cookies: Cookie[];
};

type Cookie = {
  name: string;
  value: string;
  domain?: string;
  path?: string;
  expires?: string;
  secure: boolean;
  http_only: boolean;
  same_site?: string;
};
```

| Snapshot field | Value and behaviour |
| --- | --- |
| `current_url` | Final page URL when the user completed the browser flow. |
| `html` | Final document HTML captured by the host. |
| `cookies` | Cookies visible to the platform WebView and returned as structured entries. The source should filter by expected domain and name. |

| Cookie field | Meaning |
| --- | --- |
| `name`, `value` | Required cookie pair. |
| `domain`, `path`, `expires` | Optional attributes when supplied by the platform. |
| `secure`, `http_only` | Boolean flags. `http_only` cookies can still appear because extraction is performed by the host, not page JavaScript. |
| `same_site` | Optional platform-provided SameSite label. |

## Steps

### `request`

```ts
type RequestStep = {
  type: "request";
  request: Request;
  next_state?: unknown;
  cache_key?: string;
};

type Request = {
  url: string;
  method?: string;                       // default: GET
  params?: Record<string, string>;
  headers?: Record<string, string> | [string, string][];
  body?: string | Uint8Array;
};
```

`cache_key` must be non-empty and at most 128 bytes to enable the helper
response cache. Only status-200 responses up to 1 MiB are stored.

| Field | Required | Value and behaviour |
| --- | :---: | --- |
| `type` | Yes | Must be the exact string `"request"`. |
| `request.url` | Yes | Absolute URL. The native host validates its hostname against `access_domain` after auth patching and before network access. |
| `request.method` | No | HTTP method string; defaults to `GET`. The current host also falls back to `GET` when the string is not a valid method. Sources should treat that fallback as defensive behaviour, not use it intentionally. |
| `request.params` | No | Object of string-to-string query parameters appended by the native client. Arrays and non-string values are rejected. |
| `request.headers` | No | String map for ordinary unique headers, or ordered pairs when repeated names are required. Malformed entries and non-string values are rejected. |
| `request.body` | No | Text is sent as its encoded string body; `Uint8Array` is sent byte-for-byte. Other values are rejected. Omission means no body. |
| `next_state` | No | Live value delivered as `event.state` after the request. `null` and `undefined` mean no state. |
| `cache_key` | No | Per-source helper-response key. Empty/over-128-byte keys simply disable this cache. A hit skips HTTP but still produces `event.response`. |

Before HTTP, `login.patchRequest` may return a modified request. Transient
native failures use the host retry policy without invoking the reducer between
attempts. A request step consumes one of the operation's eight internal steps.

### `compute`

```ts
type ComputeStep = {
  type: "compute";
  programs: string[];
  input?: unknown;       // defaults to null
  next_state?: unknown;
};
```

Each string is an ES module. Programs run in order in one fresh compute realm;
the last module's default export becomes `event.compute`.

| Field | Required | Value and behaviour |
| --- | :---: | --- |
| `type` | Yes | Must be `"compute"`. |
| `programs` | Yes | Array of 1–8 source strings, at most 4 MiB in total. Each is evaluated as an ES module in order. The last program must default-export a defined value. |
| `input` | No | Realm-independent value installed as compute global `input`; omission becomes `null`. Supports plain data, `undefined`, and `Uint8Array`, but not functions or host objects. |
| `next_state` | No | Live feed-realm value returned as `event.state` alongside `event.compute`. |

The compute result is copied, capped at 16 MiB, and the realm is destroyed.
This step consumes one internal step.

### `webview`

```ts
type WebviewStep = {
  type: "webview";
  url: string;
  user_agent: string;
  title?: string;
  next_state?: unknown;
};
```

The source chooses the User-Agent before navigation. It is intentionally not
returned in the snapshot.

| Field | Required | Value and behaviour |
| --- | :---: | --- |
| `type` | Yes | Must be `"webview"`. |
| `url` | Yes | Initial absolute URL opened by the platform WebView. |
| `user_agent` | Yes | User-Agent applied before first navigation; must be non-empty, contain no control characters, and be at most 512 bytes. Reuse it in later requests. |
| `title` | No | User-facing title for the browser page. |
| `next_state` | No | Value returned through `event.state` with the snapshot. |

Cancellation, lack of a WebView host, or an incomplete flow produces an
authentication-required error. A WebView step consumes one internal step.

### `complete`

```ts
type CompleteStep = {
  type: "complete";
  items?: unknown[];
  value?: unknown;
  next_cursor?: unknown;
};
```

Use `items` for search, chapters, and paragraphs. Use `value` for book info and
authentication status. Completion values must be JSON-compatible.

| Field | Required | Value and behaviour |
| --- | :---: | --- |
| `type` | Yes | Must be `"complete"`. |
| `items` | Page operations | Array for search, chapters, or paragraphs. Omission is treated as an empty page. Elements are validated against the current operation's result model. |
| `value` | Value operations | Book object or auth-status boolean. Omission becomes `null` and normally fails typed validation. |
| `next_cursor` | No | Realm-independent token for the next page. `null`/`undefined` ends pagination. Any other supported value requests another page and becomes its `event.cursor`. |

`items` and `value` are converted like JSON, capped at 16 MiB, and reject
`Uint8Array`, `BigInt`, symbols, functions, cycles, and unsupported host
objects. Array `undefined` entries become `null`; object properties with
`undefined` are omitted.

### `fail`

```ts
type FailStep = {
  type: "fail";
  code: string;
  message: string;
};
```

Prefer the global `FeedError` helpers described below.

| Field | Required | Value and behaviour |
| --- | :---: | --- |
| `type` | Yes | Must be `"fail"`. |
| `code` | Yes | Stable machine-readable string. Known codes receive host retry/login semantics; unknown codes remain expected but non-retryable. |
| `message` | Yes | User/developer-facing explanation. It must not contain credentials or signed secrets. |

## Result models

### Book/search item

```ts
type Book = {
  id: string;
  title: string;
  author: string;
  cover_url?: string | null;
  description?: string | null;
};
```

| Field | Required | Behaviour |
| --- | :---: | --- |
| `id` | Yes | Source-owned book identity. It should be non-empty, must remain stable when title/author changes, and must be unique across one search stream. |
| `title` | Yes | Display title. |
| `author` | Yes | Display author; use an explicit fallback string when the site omits it. |
| `cover_url` | No | Absolute or site-usable cover URL, or `null`. It is consumed by the application image loader rather than a reducer request. |
| `description` | No | Plain-text synopsis, or `null`. Do not return raw page HTML. |

The same shape is used by search results and `bookInfo.value`.

### Chapter

```ts
type Chapter = { id: string; title: string };
```

| Field | Required | Behaviour |
| --- | :---: | --- |
| `id` | Yes | Stable source-owned chapter identity, unique across the complete paginated directory. It should be non-empty and is later returned as `input.chapterId`. |
| `title` | Yes | User-facing chapter title in directory order. |

### Paragraph

```ts
type Paragraph =
  | { type: "title"; id?: string; text: string }
  | { type: "text"; id?: string; content: string }
  | { type: "image"; id?: string; url: string; alt?: string | null };
```

Book and chapter IDs are required, stable, and unique across all pages of one
operation. Paragraph IDs are optional; the host assigns sequential indices
when omitted.

| Variant | Fields and behaviour |
| --- | --- |
| `title` | `text` is the chapter/section heading. Optional `id` overrides the host index. |
| `text` | `content` is one plain-text paragraph. Do not include HTML tags. Optional `id` overrides the host index. |
| `image` | `url` identifies the image; optional `alt` is accessible fallback text and defaults to `null`. Optional `id` overrides the host index. |

Host-assigned indices continue across paginated paragraph pages. Explicit IDs
are strings and should only be used when the site exposes a stable identity.

## Login API

```ts
type Login = {
  entry(): AuthEntry;
  parse(page: AuthPage): object | FailStep;
  patchRequest(operation: OperationDescriptor, request: Request, auth: object): Request;
  status?(event: Event): Step;
};
```

If any login hook is present, `entry`, `parse`, and `patchRequest` must all be
present.

### `login.entry()`

```ts
type AuthEntry = {
  url: string;
  user_agent: string;
  title?: string;
};
```

`entry` takes no parameters and is called before the WebView opens.

| Return field | Required | Behaviour |
| --- | :---: | --- |
| `url` | Yes | Initial sign-in URL. |
| `user_agent` | Yes | Non-empty, control-character-free User-Agent no longer than 512 bytes, applied before navigation. |
| `title` | No | User-facing browser title. |

### `login.parse(page)`

```ts
type AuthPage = {
  current_url: string;
  response: Uint8Array;
  response_headers: [string, string][];
  cookies: Cookie[];
};
```

Return the minimum JSON-compatible cookies or tokens required for future
requests. Returning a `FeedError` failure aborts login without persisting data.

| `page` field | Behaviour |
| --- | --- |
| `current_url` | Final browser URL. Use it to confirm redirects reached a signed-in page. |
| `response` | Raw bytes of the captured final page response; decode explicitly when needed. |
| `response_headers` | Ordered header pairs for that response. |
| `cookies` | Structured cookies captured by the host, including HTTP-only entries when the platform exposes them. |

The returned auth object is persisted under the source ID and supplied later as
`event.auth` and the `auth` argument to `patchRequest`. `undefined`, bytes,
functions, cycles, and oversized values are rejected. Store only necessary
tokens/cookies, not the complete page snapshot.

### `login.patchRequest(operation, request, auth)`

```ts
type OperationDescriptor = {
  operation: Event["operation"];
  input: object;
};
```

Patch and return the request. The request contains normalized `method`,
`params`, and `headers`; an existing body is a `Uint8Array`.

| Parameter | Behaviour |
| --- | --- |
| `operation` | Fresh `{ operation, input }` descriptor for the request's current content/auth-status operation. Use it to scope credentials or headers without duplicating IDs in state. |
| `request` | Mutable request object constructed from the reducer step. `method` is always present, `params`/`headers` are objects, and `body` is absent or a byte array. |
| `auth` | Persisted JSON value returned by `parse`. |

The function runs synchronously for every native request, including each
request in a multi-step operation. It must return a complete valid `Request`;
returning `undefined` or a malformed object fails the operation. The returned
URL is still checked against the allowlist, so auth cannot widen network access.

### `login.status(event)`

Optional reducer with operation `auth_status`. Its `event.input` is empty and
normal request/compute/WebView steps are available. Complete with boolean
`value`: `true` means logged in and `false` means the stored auth has expired.
When no auth is stored, the host reports logged out without calling this hook.
When stored auth exists but `status` is omitted, the host assumes it is logged
in rather than probing the website.

## Globals

### `FeedError`

```js
FeedError.authRequired(message)       // code: auth_required
FeedError.cfChallenge(message)        // code: cf_challenge
FeedError.rateLimited(message)        // code: rate_limited
FeedError.contentNotFound(message)    // code: content_not_found
FeedError.sourceUnavailable(message)  // code: source_unavailable
FeedError.raise(code, message)
```

Every helper converts `message` with `String(message)` and returns a new
`FailStep`; it does not throw. `raise` also converts `code` to a string.

| Helper | Host meaning |
| --- | --- |
| `authRequired` | Missing/expired credentials; non-retryable without user action. |
| `cfChallenge` | Human/anti-bot challenge; non-retryable as an ordinary HTTP request. |
| `rateLimited` | Temporary throttling; classified as retryable. |
| `contentNotFound` | Missing or inaccessible content; non-retryable. |
| `sourceUnavailable` | Temporary source outage; classified as retryable. |
| `raise` | Custom expected code; preserved but non-retryable. |

### Compatibility globals

`atob`, `btoa`, `window`, `self`, `navigator`, inert `console`,
`performance.now`, and non-scheduling timer shims are available. They are
compatibility helpers, not browser capabilities.

| Global | Parameters and behaviour |
| --- | --- |
| `atob(input)` | Converts `input` to string, removes trailing padding, and returns a binary string. An impossible length throws, while characters outside the built-in alphabet are skipped by this compatibility shim. Prefer strict `Bytes.fromBase64` for byte-safe work. |
| `btoa(input)` | Converts `input` to string and returns standard padded base64 from its code units. Unlike the browser API, this shim does not strictly reject code units above 255. Prefer `Bytes.toBase64` for `Uint8Array`. |
| `window`, `self` | Aliases of `globalThis`; they do not provide a browser DOM. |
| `navigator.userAgent` | Constant compatibility value `"Langhuan QuickJS"`; it is unrelated to the WebView/request User-Agent. |
| `console.*(...)` | Accepts any arguments and does nothing; no log output is exposed. |
| `performance.now()` | Returns the current `Date.now()` value, not a high-resolution monotonic clock. |
| `setTimeout(callback, delay?)` | Calls a function callback immediately and returns `0`; it does not schedule or honour `delay`. |
| `clearTimeout(...)`, `clearInterval(...)` | No-op. |
| `setInterval(...)` | Does not call the callback and returns `0`. |

## `langhuan:encoding`

Available in feed and compute realms.

```js
import { TextDecoder, TextEncoder, Bytes } from "langhuan:encoding";
```

### `TextDecoder`

```ts
new TextDecoder(label?: string, options?: {
  fatal?: boolean;
  ignoreBOM?: boolean;
});

decoder.encoding: string;
decoder.fatal: boolean;
decoder.ignoreBOM: boolean;
decoder.decode(data?: Uint8Array, options?: { stream?: boolean }): string;
```

#### Constructor parameters

| Parameter | Type | Default | Behaviour |
| --- | --- | --- | --- |
| `label` | `string` | `"utf-8"` | Selects the character encoding. Labels are resolved with WHATWG aliases, so values such as `utf8`, `gbk`, `big5`, and `shift_jis` are accepted. An unknown label throws. |
| `options.fatal` | `boolean` | `false` | When `false`, malformed byte sequences are replaced during decoding. When `true`, the first malformed sequence throws instead. A non-boolean value throws. |
| `options.ignoreBOM` | `boolean` | `false` | When `false`, a leading BOM for the selected encoding is removed. When `true`, BOM removal is disabled and the decoded BOM remains in the returned string. A non-boolean value throws. |

The read-only properties expose the normalized encoding name and the two
constructor flags.

#### `decoder.decode(data?, options?)`

| Parameter | Type | Default | Behaviour |
| --- | --- | --- | --- |
| `data` | `Uint8Array` | Empty byte array | Bytes to decode with this decoder's selected encoding. Omitting it returns an empty string. Other input types throw. |
| `options.stream` | `boolean` | `false` | Present only for call-shape compatibility with the WHATWG API. `false` is accepted. `true` throws because Langhuan never retains partial decoder state between calls. A non-boolean value also throws. |

Each call is independent and consumes the complete `data` value. Therefore a
response split into several buffers must be joined before decoding; calling
`decode(part, { stream: true })` repeatedly is not supported.

### `TextEncoder`

```ts
new TextEncoder();
encoder.encoding: "utf-8";
encoder.encode(input?: string): Uint8Array;
```

`TextEncoder` takes no parameters and always uses UTF-8. `encoding` is the
constant string `"utf-8"`.

| Method parameter | Type | Default | Behaviour |
| --- | --- | --- | --- |
| `input` | `string` | `""` | String encoded as UTF-8. Omitting it returns an empty `Uint8Array`; a non-string value throws. |

Every call returns a newly allocated byte array.

### `Bytes`

```ts
Bytes.toBase64(data: Uint8Array, options?: { urlSafe?: boolean }): string;
Bytes.fromBase64(input: string, options?: { urlSafe?: boolean }): Uint8Array;
Bytes.toHex(data: Uint8Array): string;
Bytes.fromHex(input: string): Uint8Array;
```

#### `Bytes.toBase64(data, options?)`

| Parameter | Type | Default | Behaviour |
| --- | --- | --- | --- |
| `data` | `Uint8Array` | Required | Raw bytes to encode. |
| `options.urlSafe` | `boolean` | `false` | Uses the RFC 4648 URL-safe `-`/`_` alphabet when true; otherwise uses `+`/`/`. Output includes `=` padding in both modes. |

Returns a base64 string. Invalid argument types throw.

#### `Bytes.fromBase64(input, options?)`

| Parameter | Type | Default | Behaviour |
| --- | --- | --- | --- |
| `input` | `string` | Required | Base64 text. ASCII whitespace is ignored and final padding may be omitted. |
| `options.urlSafe` | `boolean` | `false` | Selects the URL-safe alphabet when true. The standard and URL-safe alphabets are not mixed. |

Returns a new `Uint8Array`. Padding may appear only at the end and may contain
at most two `=` characters. Invalid alphabet characters or an impossible
encoded length throw.

#### `Bytes.toHex(data)` / `Bytes.fromHex(input)`

| Function | Parameter | Behaviour |
| --- | --- | --- |
| `toHex` | `data: Uint8Array` | Returns two lowercase hexadecimal characters per byte. |
| `fromHex` | `input: string` | Accepts upper- or lowercase hexadecimal and returns a new byte array. Odd length or non-hexadecimal characters throw. |

## `langhuan:html`

Available only in the feed realm.

```js
import { HTML } from "langhuan:html";
```

```ts
HTML.parse(input: string): Document;
HTML.decodeEntities(input: string): string;

document.select(selector: string): Selection;
document.querySelectorAll(selector: string): Selection;
document.querySelector(selector: string): Node | undefined;

selection.length: number;
selection[index]: Node;
selection.first(): Node | undefined;
selection.text(): string;
selection.attr(name: string): string | undefined;
selection.attrs(): Record<string, string>;
selection.html(): string | undefined;
selection.outer_html(): string | undefined;
selection.select(selector: string): Selection;

node.tagName: string;
node.text(): string;
node.textContent: string;
node.attr(name: string): string | undefined;
node.getAttribute(name: string): string | undefined;
node.attrs(): Record<string, string>;
node.html(): string | undefined;
node.outer_html(): string | undefined;
node.select(selector: string): Selection;
node.querySelectorAll(selector: string): Selection;
node.querySelector(selector: string): Node | undefined;
node.parent: Node | undefined;
node.children: Selection;
```

The parser is read-only and backed by Rust `scraper`; none of these objects can
modify the document.

### Namespace functions

| Function | Parameters | Return and behaviour |
| --- | --- | --- |
| `HTML.parse` | `input: string` | Parses one HTML document and returns a `Document`. Empty/blank input, non-string input, or input larger than 4 MiB throws. |
| `HTML.decodeEntities` | `input: string` | Parses the input as an HTML fragment and returns its text, decoding entities. Input larger than 4 MiB throws. |

### Document methods

Every selector parameter is a CSS selector string. Invalid syntax throws.

| Method | Return and behaviour |
| --- | --- |
| `select(selector)` | Returns every matching element in document order. |
| `querySelectorAll(selector)` | Alias of `select`. |
| `querySelector(selector)` | Returns the first matching node or `undefined`. |

Selectors support tags, `#id`, `.class`, descendant and child combinators,
comma groups, and attribute operators `=`, `*=`, `^=`, `$=`, `~=`, and `|=`.

### Selection methods

A `Selection` is an array-like snapshot with numeric entries and `length`.

| Method | Parameters | Return and behaviour |
| --- | --- | --- |
| `first()` | None | First node or `undefined` for an empty selection. |
| `text()` | None | Concatenated text of every selected node in order. `<br>` becomes `\n`; `script` and `style` content is skipped. |
| `attr(name)` | `name: string` | Attribute from the first node, or `undefined` when absent/empty. |
| `attrs()` | None | New attribute map for the first node, or an empty object. |
| `html()` | None | Inner HTML of the first node, or `undefined`. |
| `outer_html()` | None | Outer HTML of the first node, or `undefined`. |
| `select(selector)` | `selector: string` | Unique matching descendants of all selected roots, preserving traversal order. |

### Node properties and methods

| Member | Parameters | Return and behaviour |
| --- | --- | --- |
| `tagName` | — | Lowercase element name. |
| `text()` / `textContent` | None / — | Descendant text using the same `<br>`, `script`, and `style` rules as selection text. |
| `attr(name)` / `getAttribute(name)` | `name: string` | Attribute value or `undefined`. The two names refer to the same function. |
| `attrs()` | None | New object containing every attribute. |
| `html()` | None | Inner HTML. |
| `outer_html()` | None | Outer HTML. |
| `select(selector)` / `querySelectorAll(selector)` | `selector: string` | Matching descendants of this node. |
| `querySelector(selector)` | `selector: string` | First matching descendant or `undefined`. |
| `parent` | — | Nearest parent element or `undefined`. |
| `children` | — | Selection of direct child elements; text nodes are excluded. |

## `langhuan:crypto`

Available in feed and compute realms.

```js
import { Crypto, Compression } from "langhuan:crypto";
```

### Digests, HMAC, and random bytes

```ts
Crypto.md5(data: Uint8Array): Uint8Array;
Crypto.sha1(data: Uint8Array): Uint8Array;
Crypto.sha256(data: Uint8Array): Uint8Array;
Crypto.sha512(data: Uint8Array): Uint8Array;
Crypto.sm3(data: Uint8Array): Uint8Array;
Crypto.hmac(algorithm: "md5" | "sha1" | "sha256" | "sha512" | "sm3",
            key: Uint8Array, data: Uint8Array): Uint8Array;
Crypto.randomBytes(length: number): Uint8Array;
```

| Function | Parameters | Return and behaviour |
| --- | --- | --- |
| `md5`, `sha1`, `sha256`, `sha512`, `sm3` | `data: Uint8Array` | Returns raw digest bytes, not hexadecimal text. Use `Bytes.toHex` when text is needed. |
| `hmac` | `algorithm`, `key`, `data` | Returns raw HMAC bytes. `algorithm` must be one of the five lowercase names shown above; an unknown name throws. Keys may have any byte length. |
| `randomBytes` | `length: number` | Returns cryptographically secure bytes from the system RNG. `length` must be an integer from 1 through 1,048,576; invalid values or RNG failure throw. |

All byte inputs are required `Uint8Array` values and all returned arrays are
new allocations.

### AES

```ts
Crypto.aes({
  op: "encrypt" | "decrypt",
  mode: "cbc" | "ecb" | "ctr" | "gcm",
  key: Uint8Array,          // 16, 24, or 32 bytes
  iv?: Uint8Array,          // required except ECB
  data: Uint8Array,
  padding?: "pkcs7" | "none",
  aad?: Uint8Array,         // GCM only
}): Uint8Array;
```

| Option | Required | Behaviour |
| --- | :---: | --- |
| `op` | Yes | `"encrypt"` encrypts; `"decrypt"` decrypts. Other strings throw. |
| `mode` | Yes | Selects CBC, ECB, big-endian 128-bit-counter CTR, or GCM. |
| `key` | Yes | AES key of exactly 16, 24, or 32 bytes. |
| `iv` | By mode | CBC and CTR require exactly 16 bytes. GCM requires a 12-byte nonce. ECB requires this field to be omitted. |
| `data` | Yes | Plaintext for encryption; ciphertext for decryption. GCM decryption expects the authentication tag appended to the ciphertext. |
| `padding` | No | CBC/ECB default to `"pkcs7"`; `"none"` requires block-aligned data. CTR/GCM permit omission or explicit `"none"` only. |
| `aad` | No | Additional authenticated data for GCM; defaults to empty bytes. It does not appear in the returned ciphertext. The current implementation ignores it in non-GCM modes. |

Returns a newly allocated byte array. GCM encryption returns
`ciphertext || 16-byte tag`; decryption authenticates and removes that tag.
Inputs outside these length and option requirements are invalid. Bad padding
and failed GCM authentication surface as errors. CTR encryption and decryption
are the same operation internally; `op` is still required for a uniform API.

### Signing ciphers

```ts
Crypto.simon(key: Uint8Array, data: Uint8Array): Uint8Array;
Crypto.speck(key: Uint8Array, data: Uint8Array): Uint8Array;
```

These are encrypt-only Simon128/256 and Speck128/256 helpers with 32-byte keys,
ECB, and PKCS#7 for app signing protocols. `key` must be exactly 32 bytes;
`data` may have any length and a new padded ciphertext is returned. They do not
provide decryption. Prefer AES elsewhere.

### Compression

```ts
Compression.gzip(data: Uint8Array): Uint8Array;
Compression.gunzip(data: Uint8Array): Uint8Array;
Compression.deflateRaw(data: Uint8Array): Uint8Array;
Compression.inflateRaw(data: Uint8Array): Uint8Array;
```

| Function | Input and behaviour |
| --- | --- |
| `gzip` | Encodes `data` as a complete gzip member using the default compression level. |
| `gunzip` | Decodes gzip data. Malformed/truncated input throws. |
| `deflateRaw` | Encodes a raw DEFLATE stream without zlib or gzip headers. |
| `inflateRaw` | Decodes a raw DEFLATE stream. Supplying zlib/gzip-wrapped data throws. |

Each function requires `data: Uint8Array` and returns a new `Uint8Array`.
Decompression aborts if output would exceed 32 MiB.

## `langhuan:protobuf`

Available in feed and compute realms.

```js
import { Protobuf } from "langhuan:protobuf";

const writer = new Protobuf();
writer.varint(1, 150);
writer.string(2, "value");
writer.bytes(3, byteArray);
const message = writer.finish();
```

```ts
new Protobuf();
writer.varint(field: number, value: number): void;
writer.string(field: number, value: string): void;
writer.bytes(field: number, value: Uint8Array): void;
writer.finish(): Uint8Array;
```

`new Protobuf()` takes no parameters and creates an empty mutable writer.

| Method | Parameters | State and return behaviour |
| --- | --- | --- |
| `varint` | `field: number`, `value: number` | Appends a wire-type-0 field. `field` must be an integer from 1 through 536870911. `value` must be an exactly represented non-negative integer from 0 through 9,007,199,254,740,992. Returns `undefined`. |
| `string` | `field: number`, `value: string` | UTF-8 encodes `value` and appends a length-delimited field. Returns `undefined`. |
| `bytes` | `field: number`, `value: Uint8Array` | Appends a length-delimited byte field. Use this for nested messages by passing another writer's `finish()` result. Returns `undefined`. |
| `finish` | None | Returns a copy of the current message. It does not reset or consume the writer and may be called repeatedly. |

Calls append in invocation order; repeated field numbers are allowed. The
message may not exceed 32 MiB. Invalid field/value types, an unsafe varint, or
size overflow throw.

## `langhuan:storage`

Available only in the feed realm when the host installs its source-scoped
storage backend.

```js
import { storage } from "langhuan:storage";

storage.get(key);          // JSON value or undefined
storage.set(key, value);   // JSON-compatible; not undefined
storage.delete(key);
```

Every key is a string whose UTF-8 representation is 1–256 bytes. Storage is
namespaced by source ID, persists across source reloads and app restarts, and
is not available in compute realms.

| Method | Parameters | Return and behaviour |
| --- | --- | --- |
| `get` | `key: string` | Returns a fresh JavaScript representation of the stored JSON value, or `undefined` when the key is absent. Backend errors throw. |
| `set` | `key: string`, `value: JSON-compatible value` | Serializes and replaces the value through the host backend. Returns `undefined`. The value must not contain `undefined`, functions, cycles, host objects, or typed arrays. |
| `delete` | `key: string` | Removes the key if present. Missing keys are not an error. Returns `undefined`; backend failures throw. |

Encode byte arrays with `Bytes.toBase64` or `Bytes.toHex` before storing them.

For resource ceilings and realm availability, see [Sandbox](sandbox.md).

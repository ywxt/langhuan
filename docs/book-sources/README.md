# Book Source Guide

Langhuan book sources are JavaScript reducers executed by an isolated native
QuickJS runtime. A source describes requests as plain data; it cannot open
sockets, files, processes, environment variables, or native APIs.

Current examples:

- [`biquge-tw.js`](biquge-tw.js) — ordinary HTML pages.
- [`qidian.js`](qidian.js) — login, additional API requests, and purchased VIP
  chapter decryption using the site's official JavaScript bundle.
- [`fanqie.js`](fanqie.js) — server-rendered pages whose text is font-obfuscated
  (decoded through an embedded glyph table pinned to the served font), with
  keyword search via the site's JSON API (POST with query-string parameters;
  plain GETs are risk-control challenged) and an interactive WebView
  verification fallback for when the search endpoint is risk-gated.

There is no legacy runtime compatibility. Schema 3 sources must use `.js` and
must return their Feed object. Assigning `globalThis.feed` is not supported.

## Metadata

Every file starts with a comment header:

```js
// ==Feed==
// @id           example
// @name         Example Source
// @version      3.0.0
// @author       You
// @description  Example schema-3 source
// @base_url     https://example.com
// @access_domain example.com
// @access_domain *.static.example.com
// @schema_version 3
// ==/Feed==
```

`id`, `name`, `version`, `base_url`, and `schema_version` are required. Declare
every hostname the Rust host may contact with one `access_domain` line. A
leftmost wildcard such as `*.static.example.com` permits subdomains but not the
root `static.example.com`; other wildcard positions are rejected. Domain checks
apply to every request descriptor returned by the source.

The runtime exposes the parsed header as the frozen global `meta` object.

## Return contract

Use an IIFE so the source can keep helpers private and return one object:

```js
(() => {
  "use strict";

  function search(event) { /* reducer */ }
  function bookInfo(event) { /* reducer */ }
  function chapters(event) { /* reducer */ }
  function paragraphs(event) { /* reducer */ }

  return { search, bookInfo, chapters, paragraphs };
})()
```

The four handlers are required. `login` is optional:

```js
return { search, bookInfo, chapters, paragraphs, login };
```

The source is evaluated once when it is loaded. Its returned object remains in
that feed's native QuickJS context and all later operations call the retained
methods. Do not mutate globals to register handlers.

## Reducer model

Each operation is a synchronous reducer. It receives an event and returns one
of five steps:

```ts
type Event = {
  operation: "search" | "book_info" | "chapters" | "paragraphs" | "auth_status";
  input: object;
  cursor: unknown;
  state: unknown;
  response: null | {
    status: number;
    headers: [string, string][];
    body: string;
    url: string;
  };
  compute: unknown | null;
  auth: null | object;
  webview: null | {
    current_url: string;
    html: string;
    cookies: { name: string; value: string; domain?: string }[];
    user_agent?: string;
  };
};

type Step =
  | { type: "request"; request: Request; next_state?: unknown; cache_key?: string }
  | { type: "compute"; programs: string[]; input?: unknown; next_state?: unknown }
  | { type: "webview"; url: string; title?: string; next_state?: unknown }
  | { type: "complete"; items?: unknown[]; value?: unknown; next_cursor?: unknown }
  | { type: "fail"; code: string; message: string };
```

On the first call, `state`, `response`, and `compute` are `null`. Return a
request. Rust validates and performs it, then calls the same reducer with the
response and the provided `next_state`. This can repeat for multi-step flows
such as Qidian:

```text
chapter HTML -> chapter API -> official decryptor bundle -> isolated compute -> complete
```

The script never performs HTTP itself.

### Request descriptor

```js
{
  url: "https://example.com/search",
  method: "GET",                 // defaults to GET
  headers: { Accept: "text/html" },
  params: { q: "keyword" },      // URL query parameters
  body: null,
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
    event.response.body,
    "decrypt(input.encrypted, input.key)",
  ],
  input: { encrypted, key },
  next_state: { stage: "decrypted" },
};
```

Rust creates a fresh QuickJS realm for each compute step, installs no native
callbacks, network API, HTML parser, module loader, filesystem, process, or
environment access, and evaluates `programs` in order. Only JSON `input` enters
the realm and only the final program's JSON value returns as `event.compute`.
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
  next_state: { stage: "verified" },
};
```

The host opens the page in a platform WebView (embedded on Android, iOS and
macOS; a separate window on Linux and Windows), the user completes the
interaction, and the page snapshot — final URL, HTML, the cookies collected
so far, and the WebView's User-Agent — comes back as `event.webview` with
`next_state`, letting the reducer continue:

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
      headers: { Cookie: cookies, "User-Agent": event.webview.user_agent },
    },
    next_state: { stage: "results" },
  };
}
```

Replays should reuse `event.webview.user_agent` verbatim: cookie-based
clearances (for example Cloudflare's `cf_clearance`) are issued for the
User-Agent that solved the challenge, and a replay under a different string
can be rejected even with the right cookies.

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

The sandbox provides `HTML.parse()` through a bounded, read-only Rust binding
powered by `scraper`. This is the only native object exposed to source code; it
does not provide filesystem, network, process, environment, or other system
access. Each input is limited to 4 MiB and returns a document tree with CSS
selection:

```js
const document = HTML.parse(event.response.body);
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

## Authentication

The optional `login` object contains:

```js
const login = {
  entry() {
    return { url: "https://example.com/login", title: "Sign in" };
  },

  parse(page) {
    // page: { current_url, response, response_headers, cookies, user_agent? }
    const session = page.cookies.find((cookie) => cookie.name === "session");
    if (!session) return FeedError.authRequired("Login is incomplete");
    return { cookie_header: `session=${session.value}`, user_agent: page.user_agent ?? null };
  },

  patchRequest(operation, request, auth) {
    request.headers ??= {};
    request.headers.Cookie = auth.cookie_header;
    if (auth.user_agent) request.headers["User-Agent"] = auth.user_agent;
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

`page.user_agent` carries the WebView's User-Agent for the same reason as the
webview step: sessions captured in a browser are bound to the User-Agent they
were issued under, so `parse` should store it and `patchRequest` replay it.

## Sandbox guarantees and limits

Every loaded feed owns one native QuickJS runtime and context. The source and
built-ins are evaluated once; the returned Feed object is retained. Reducer
calls are serialized per feed, and the execution deadline is reset for every
call:

- no filesystem, sockets, environment, subprocesses, dynamic modules, or host
  object references;
- 32 MiB QuickJS heap and a 1 MiB QuickJS stack;
- a 30-second JavaScript deadline enforced by QuickJS's interrupt handler;
- a 16 MiB serialized-result limit;
- no state sharing between different feeds;
- JSON-only arguments and results, capped by the host;
- all network, authentication, caching, redirects, and domain checks remain in
  native Rust.

Browser globals are not generally available. The runtime supplies only small
pure helpers needed by site code: `atob`, `window/self` aliases, inert
`console`, `performance.now`, and inert timer shims. `navigator` deliberately
has no `webdriver` property so official anti-bot bundles do not mistake the
sandbox for browser automation.

## Ordinary and multi-request sources

The same reducer contract covers both kinds of site:

- An ordinary HTML source returns one `request`, parses `response.body`, and
  returns `complete`.
- A site such as Qidian stores intermediate values in `next_state`, returns
  another request descriptor, evaluates pure site-provided decryption code in
  the guest, and finally returns `complete`.

Neither source receives an HTTP function. The difference is only the number of
request steps it describes.

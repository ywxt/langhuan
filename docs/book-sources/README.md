# Book sources

A Langhuan book source is a small JavaScript ES module that teaches the app how
to find and read books from one service. It parses pages and makes decisions,
but it does not perform network requests itself. The native host owns HTTP,
authentication, caching, retries, and policy enforcement.

This split lets the same source contract cover a simple HTML catalogue and a
site that needs login, several API calls, or content decryption without giving
third-party scripts unrestricted system access.

## Documentation map

| Document | Use it for |
| --- | --- |
| [Architecture](architecture.md) | Understand reducers, request execution, pagination, state, caching, and authentication. |
| [Writing a source](writing-a-source.md) | Build a complete schema-4 source from metadata to readable paragraphs. |
| [Sandbox](sandbox.md) | Understand what scripts can do, what they cannot do, and every resource limit. |
| [API Reference](api-reference.md) | Look up metadata, events, steps, result shapes, login hooks, globals, and `langhuan:*` modules. |
| [Error handling](../error-handling.md) | Choose expected failures and understand host error categories. |
| [Debug tools](../feed-debug-tools.md) | Inspect reducer stages and native request traces in developer mode. |

## The model in one minute

Every source exports four synchronous reducer functions:

```js
export default {
  search,
  bookInfo,
  chapters,
  paragraphs,
};
```

On the first call, a reducer returns a request descriptor. Rust validates and
executes it, then calls the same reducer again with the response. The reducer
can complete, describe another request, ask for isolated computation, open a
human verification WebView, or return an expected failure.

```text
App operation
    │
    ▼
JavaScript reducer ── returns data ──► Rust policy + HTTP
    ▲                                      │
    └──────── event.response ──────────────┘
    │
    └── complete(items/value) ──► cache ──► reader UI
```

The source never receives `fetch`, sockets, or a native HTTP object.

## Start with an example

- [`biquge-tw.js`](biquge-tw.js) is the best starting point: ordinary HTML,
  CSS selectors, and one request per stage.
- [`qidian.js`](qidian.js) demonstrates login, authenticated requests,
  additional chapter API calls, and isolated execution of a site decryptor.
- [`fanqie.js`](fanqie.js) demonstrates WebView verification, session cookies,
  pagination, and font-obfuscated text.
- [`fanqie-app.js`](fanqie-app.js) demonstrates persistent source storage,
  binary protocols, request signing, compression, and encrypted content. It is
  GPL-3.0-or-later; the other examples are covered by the repository license.

For a new source, copy the structure—not site-specific tokens, cached script
URLs, device identifiers, or authentication data.

## Compatibility

The current contract is schema 4:

- source files use `.js`;
- they are ES modules;
- they `export default` the Feed object;
- HTTP response bodies are `Uint8Array` values;
- `globalThis.feed` and legacy schema-3 registration are not supported.

Continue with [Architecture](architecture.md), then follow
[Writing a source](writing-a-source.md).

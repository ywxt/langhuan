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
| [Writing a source](writing-a-source.md) | Build a complete schema-6 source from metadata to readable paragraphs. |
| [Sandbox](sandbox.md) | Understand what scripts can do, what they cannot do, and every resource limit. |
| [API Reference](api-reference.md) | Look up metadata, events, steps, result shapes, login hooks, globals, and `langhuan:*` modules. |
| [Error handling](error-handling.md) | Choose expected failures and understand host error categories. |
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
    └── complete(result) ──► cache ──► reader UI
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
- [`jjwxc.js`](jjwxc.js) demonstrates a GBK-encoded site: decoding GBK pages,
  percent-encoding search keywords to GBK with `HTML.encodeURIComponent`,
  paragraph-aligned comments from JSON APIs without login, and VIP chapters
  failing with an auth-required error.

For a new source, copy the structure—not site-specific tokens, cached script
URLs, device identifiers, or authentication data.

## Current contract

The current contract is schema 6:

- source files use `.js`;
- they are ES modules;
- they `export default` the Feed object;
- HTTP response bodies are `Uint8Array` values;
- requests carry a full URL — scripts build their own query strings and
  percent-encode them with `HTML.encodeURIComponent`;
- the HTML module follows the jQuery and browser DOM interface (`find`,
  `parent()`, `children()`, `outerHTML()`, …);
- `globalThis.feed` and schemas below 6 are rejected; old completion shapes are not adapted.

## Local Agent API

The **Agent API** action on the [developer tools](../feed-debug-tools.md) page
starts an ephemeral HTTP server for local AI agents, editors, and
command-line tools. It binds only to `127.0.0.1` on a random port,
requires the displayed random Bearer token, accepts one run at a time, and
stops when the developer page closes. Request bodies are limited to 2 MiB.

Routes are flat beneath `/v1`: `/run`, `/load`, `/reload`, `/health`,
and `/operations`.
HTTP control fields, mode names, and output type tags use `snake_case`, such as
`feed_id`, `single_page`, and `bookInfo`. The `operation` name and keys inside
`input` follow the feed/debugger protocol unchanged (`bookInfo`, `bookId`,
`chapterId`, `login.status`); single-page debugging passes raw input and cursors
through without renaming script-defined fields. The `/v1/operations` catalogue is
self-describing: authentication, every endpoint's method, path, request and
response shape, a runnable example, pagination, limits, error codes, and a
GitHub link to the contract section of every operation.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/health` | Server identity and API version |
| `GET` | `/v1/operations` | Supported exports and input fields |
| `POST` | `/v1/run` | Execute one export and return output, steps, and HTTP trace |
| `POST` | `/v1/load` | Replace and persist the developer editor's script |
| `POST` | `/v1/reload` | Read the last successfully loaded source again |

`POST /v1/load` accepts exactly one non-empty string field:

- `script`: inline JavaScript, copied into the editor unchanged.
- `path`: an absolute path to a UTF-8 file on the machine running Langhuan.
  Files are limited to 2 MiB; remote URLs and relative paths are not accepted.
- `feed_id`: copies the current script of an installed feed into the editor.

For example, load a local file:

```sh
curl -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"path":"/absolute/path/qidian.js"}' "$BASE/v1/load"
```

After saving changes to that file, `POST /v1/reload` with an empty body
or `{}` reads it again. For `feed_id`, reload reads the installed script again;
for `script`, it restores the original inline source. Reload requires a previous
successful load in this developer-page session. Failed loads preserve the
editor and previous source selection. Script syntax is checked when running,
so incomplete scripts can still be loaded for editing.

Both endpoints require the Bearer token. They return `409` while the workspace
is running or importing; malformed sources and unreadable/non-UTF-8 files return
`400`, oversized files return `413`. Successful responses contain `ok`, `source`
(`script`, `path`, or `feed_id`), `bytes` (UTF-8 byte count), and the `path` or
`feed_id` when applicable. They do not install or replace production feeds.
Subsequent `/v1/run` calls without `script` or `feed_id` use the updated editor.

`POST /v1/run` accepts an inline `script`, an installed `feed_id`, or neither
(which uses the current editor contents):

```json
{
  "feed_id": "org.eu.ywxt.langhuan.example",
  "operation": "search",
  "input": { "keyword": "example" }
}
```

The other operation inputs are `{ "bookId": "..." }` for `bookInfo` and
`chapters`, `{ "bookId": "...", "chapterId": "..." }` for `paragraphs`,
and an empty object for `login.status`. Responses contain typed output,
structured failures, reducer steps, and masked HTTP data.

By default the API uses `"mode": "pipeline"` and follows all cursors, matching
the UI's typed stages. Comment operations accept `bookId`, `chapterId`, an
optional `parentId` for existing replies, and `paragraphId` for paragraph
comments. They never publish or modify comments. Set `"mode": "single_page"`
and optionally provide `"cursor"` to execute only one page:

```json
{
  "operation": "search",
  "mode": "single_page",
  "input": { "keyword": "example" },
  "cursor": { "page": 2 }
}
```

Omitting `cursor` is equivalent to `null`. The response includes
`output.next_cursor`, which can be supplied unchanged to the next call.

Continue with [Architecture](architecture.md), then follow
[Writing a source](writing-a-source.md).

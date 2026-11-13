# Book-source developer tools

Langhuan includes an isolated stage runner for developing schema-6 sources on
the same device that runs the app. It loads the editor's script into a
stateful debug environment and executes it there; a work-in-progress source
does not need to be installed first.

## Opening the tools

Developer mode is hidden by default. Unlock it from Settings, then open the
developer-tools page. The page keeps the current editor text locally so an
accidental navigation does not discard a long script.

On screens at least 1100 logical pixels wide, the page becomes a three-column
workbench: source editor, operation launcher/history, and result inspector.
Narrow windows retain the single-column layout.

You can paste a source or load the current script of an installed source into
the editor. Loading is read-only: debug runs never replace the installed
script, source registry, bookshelf, or caches.

## The debug environment

The environment is the loaded script, and it is stateful. Opening the page
loads the restored editor contents; the **Load** action compiles the current
editor contents into the environment (and so does importing from an installed
feed, or an Agent API `/v1/load`). Runs always execute the loaded script —
never the editor text — so:

- module state and `langhuan:storage` writes persist across runs of one load,
  which is what makes incremental flows (register once, then reuse) debuggable;
- every load compiles over a fresh engine: state, storage, and module
  variables reset, so a reload starts from a clean slate;
- the environment lives exactly while the developer page is open — closing
  the page drops the script with everything it wrote.

`langhuan:storage` is therefore available in the tools: it is backed by the
environment's in-memory storage, namespaced by source id, and never touches
the persistent storage of installed feeds. Webview steps run through the same
interactive verification page as production: a gated run pauses until you
finish verifying in the app's WebView, and the snapshot flows back into the
run's result.

## Stage runner

Choose one stage and enter its input:

| Stage | Input | Output |
| --- | --- | --- |
| Search | Keyword | Every search result page |
| Book info | Book ID | Parsed book metadata |
| Chapters | Book ID | Complete chapter directory |
| Paragraphs | Book ID and chapter ID | Parsed paragraph list |
| Auth status | None | Logged-in, logged-out, or expired status |
| Advanced single page | Operation, input JSON, cursor JSON | One raw reducer result and `next_cursor` |

Each operation is independently callable; selecting Search invokes only the
feed's exported `search` reducer, for example. Each run executes the loaded
source object in the production sandbox and uses the production request,
reducer, domain-policy, authentication-patching, and parser paths. It does not
use normal response or bookshelf caches.

The five typed stages are the default and preserve the normal app behaviour:
streaming operations automatically follow `next_cursor` until completion.
Choose **Advanced single page** when debugging pagination itself. It accepts
one of `search`, `bookInfo`, `chapters`, `paragraphs`, `login.status`,
`comments.chapter`, or `comments.paragraph`, passes
the JSON object directly as `event.input`, and passes the cursor JSON as
`event.cursor`. `null` means the first page. The runner executes exactly one
page and displays raw `result` and `next_cursor`; **Use next cursor**
copies the returned cursor into the next run.

Single-page comment results still follow the comment contract: `result` must
be a `Comment[]`, with each item's required fields and limits validated before
it is returned. Legacy `{ items, total_count }` wrappers are rejected.
The Agent API's typed paragraph output includes `comment_count`: `null` means
unknown, while `0` is a known empty thread. Counts for generated identities
remain ignored, just as in the reader.

This does not invent pagination for a source. The selected reducer must read
`event.cursor` (or a page field in `event.input`) and return `next_cursor` when
another page exists.

If an installed source with the same ID has stored authentication, the runner
hydrates that value read-only. The result shows whether authentication is not
supported, missing, or applied.

## Results and partial output

A run reports:

- compiled source identity and version;
- typed stage output;
- terminal error and error category;
- total duration;
- authentication usage;
- native HTTP trace;
- every reducer step returned by the selected export.

Search, chapter, and paragraph stages retain items parsed before a later page
fails. Partial output and the terminal error are shown together, which makes a
bad cursor or one malformed page visible.

The page keeps an in-memory run history so results can be compared while
editing. Restarting the app clears run results; editor text is persisted.

## HTTP inspector

Every native request made during the run appears in execution order with:

- method and requested URL;
- final URL after redirects;
- response status, size, and elapsed time;
- request headers with sensitive values masked;
- a bounded response-body preview;
- native error details;
- requests rejected by the domain allowlist.

The recorder is scoped to the debug run. Traces remain in memory, have bounded
entry/body budgets, and are dropped on restart. The result reports how many
entries were omitted after the limit.

## Reducer step inspector

The step inspector records each reducer round in execution order. It shows the
operation, zero-based round, step type, and a bounded summary:

- `request`: method, redacted URL, and cache key;
- `compute`: program count and input size;
- `webview`: title and redacted URL;
- `complete`: item count, value presence, and next-cursor presence;
- `fail`: expected-error code and message.

The recorder is task-local and bounded. Normal feed runs do not enable it, so
production execution does not retain reducer state or debug payloads.

## Local Agent API

The **Agent API** action starts an ephemeral HTTP server for local AI agents,
editors, and command-line tools. It binds only to `127.0.0.1` on a random port,
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
GitHub link to the book-source documentation for every operation.

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
editor and previous source selection. Loading compiles the script into the
debug environment, so sources that fail to compile are rejected; the
environment's state resets with every successful load.

Both endpoints require the Bearer token. They return `409` while the workspace
is running or importing; malformed sources and unreadable/non-UTF-8 files return
`400`, oversized files return `413`. Successful responses contain `ok`, `source`
(`script`, `path`, or `feed_id`), `bytes` (UTF-8 byte count), and the `path` or
`feed_id` when applicable. They do not install or replace production feeds.
Subsequent `/v1/run` calls execute the newly loaded script.

`POST /v1/run` executes the loaded script. The body carries the operation and
its input (inline `script` and `feed_id` fields are not accepted — load them
with `/v1/load` first):

```json
{
  "operation": "search",
  "input": { "keyword": "example" }
}
```

The other operation inputs are `{ "bookId": "..." }` for `bookInfo` and
`chapters`, `{ "bookId": "...", "chapterId": "..." }` for `paragraphs`,
and an empty object for `login.status`. Responses contain typed output,
structured failures, reducer steps, and masked HTTP data. A run before any
script is loaded (or with legacy `script`/`feed_id` fields) returns `400`.

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

## Safety properties

The developer tools observe the production path; they do not widen it:

- the source still has no HTTP or system API;
- `@access_domain` enforcement remains active;
- stored auth is read-only;
- cookie, authorization, and known secret values are masked;
- editor contents are not installed or written to the source database;
- trace data does not leave the device.
- the Agent API is opt-in, loopback-only, token protected, and lifetime-bound
  to the open developer page.

Avoid putting credentials in source code or error messages: source text and
script-provided messages cannot be reliably redacted.

## Recommended workflow

1. Run search with a keyword that has known results and an empty-result query.
2. Copy one result ID into book info.
3. Run chapters and inspect the first, middle, and last IDs.
4. Run paragraphs for free, protected, and late chapters as applicable.
5. Run auth status before and after login.
6. Check every trace host against the metadata allowlist.
7. Test a second search page and verify IDs do not repeat.
8. Only then import the source through the normal safety preview.

The stage runner does not pause the QuickJS VM or expose arbitrary heap objects.
Step inspection observes reducer boundaries instead: use explicit state, small
parsing helpers, typed expected errors, and the HTTP trace to locate failures.

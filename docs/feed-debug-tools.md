# Book-source developer tools

Langhuan includes an isolated stage runner for developing schema-4 sources on
the same device that runs the app. It executes editor contents directly; a
work-in-progress source does not need to be installed first.

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
feed's exported `search` reducer, for example. Each run compiles a fresh source
object in the production sandbox and uses the production request, reducer,
domain-policy, authentication-patching, and parser paths. It does not use
normal response or bookshelf caches.

The five typed stages are the default and preserve the normal app behaviour:
streaming operations automatically follow `next_cursor` until completion.
Choose **Advanced single page** when debugging pagination itself. It accepts
one of `search`, `bookInfo`, `chapters`, `paragraphs`, or `authStatus`, passes
the JSON object directly as `event.input`, and passes the cursor JSON as
`event.cursor`. `null` means the first page. The runner executes exactly one
page and displays raw `items`, `value`, and `next_cursor`; **Use next cursor**
copies the returned cursor into the next run.

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

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/health` | Server identity and API version |
| `GET` | `/v1/operations` | Supported exports and input fields |
| `POST` | `/v1/run` | Execute one export and return output, steps, and HTTP trace |

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
and an empty object for `authStatus`. Responses contain typed output,
structured failures, reducer steps, and masked HTTP data.

By default the API uses `"mode": "pipeline"` and follows all cursors, matching
the UI's typed stages. Set `"mode": "singlePage"` and optionally provide
`"cursor"` to execute only one page:

```json
{
  "operation": "search",
  "mode": "singlePage",
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

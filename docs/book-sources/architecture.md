# Book-source architecture

Langhuan separates source-specific decisions from privileged work. JavaScript
knows the target website; Rust owns the network, persistence, authentication,
resource limits, and application-facing data model.

## Components and responsibilities

| Part | Responsibility |
| --- | --- |
| Source metadata | Identity, version, base URL, and the complete network-domain allowlist. |
| Feed realm | Retains the exported source object and runs reducers serially for one source. |
| Reducer runtime | Turns an app operation into request, compute, WebView, completion, or failure steps. |
| Native HTTP host | Validates domains, patches authentication, retries transient failures, limits bodies, and records safe traces. |
| Compute realm | Runs explicitly supplied site code without source state, HTML, storage, network, or system access. |
| Login/WebView host | Lets the user authenticate or solve a human-only challenge and returns a bounded page snapshot. |
| Cache and database | Cache source results, store source-scoped state, preserve bookshelf data, progress, and bookmarks. |
| Hub/UI | Exposes search as a cancellable stream and finite book, chapter, and paragraph results as values. |

## One contract for simple and complex sites

An ordinary HTML source typically needs two reducer rounds:

```text
search(event without response)
  -> request /search?q=...
search(event.response)
  -> complete(result)
```

A protected chapter may need more rounds:

```text
chapter page
  -> discover API and current decryptor URL
chapter API
  -> obtain encrypted payload
decryptor asset
  -> obtain site program
compute
  -> run program with minimum required input
complete
```

Both use the same five step types. Complexity changes the number of described
steps, not the privileges granted to the source.

## Operation lifecycle

The app starts one of these operations:

| Handler | Input | Completion |
| --- | --- | --- |
| `search` | `{ keyword }` | book array in `result` and optional `next_cursor` |
| `bookInfo` | `{ bookId }` | one book in `result` |
| `chapters` | `{ bookId }` | chapter array in `result` and optional `next_cursor` |
| `paragraphs` | `{ bookId, chapterId }` | paragraph array in `result` and optional `next_cursor` |
| `login.status` | empty object | boolean `result` |

Each call receives an event. On the first round, `state`, `response`,
`compute`, and `webview` are absent. A non-terminal step is executed by the
host and its outcome appears on the next call:

```js
function chapters(event) {
  if (event.state == null) {
    return {
      type: "request",
      request: { url: `${meta.base_url}/books/${event.input.bookId}` },
      next_state: { stage: "directory" },
    };
  }

  return { type: "complete", result: parseDirectory(event.response.body) };
}
```

Reducers are synchronous. They do not return promises and cannot wait on
timers. Asynchrony exists between reducer calls, where the native host performs
the requested work.

## Pagination and result delivery

`search` can emit a page with `next_cursor`. Results remain incremental and
cancellable. Single-source and aggregated searches cross the Rust/Flutter
bridge in batches of at most 20 items/events (`nextBatch()`), and the Dart
service exposes `Stream<List<...>>`. Flutter buffers each received batch for
UI pagination instead of crossing the bridge once per book.

Once the first event arrives, both native batching and UI accumulation wait
at most a 40 ms coalescing window instead of waiting indefinitely for 20
events. Each aggregated source releases its shared concurrency permit after
each stream advance, before waiting on result delivery. A multi-page source
therefore cannot reserve a search slot for its entire lifetime. This does not
promise equal result counts or cross-source relevance ordering.

See [search, comments, and listening design](../search-comments-listening.md)
for scheduling, source-comment interfaces, typed paragraph identity, and local TTS.

A bridge batch is independent from a source page: it may split a large source
page or combine smaller pages. The source's `result` and top-level `next_cursor` contract
is unchanged, and producers retain bounded-channel backpressure. A terminal
error after some results does not discard them: the partial batch is returned
first and the next pull reports the error.

`chapters` and `paragraphs` use the same cursor contract inside the source
runtime, but the app needs their complete finite results before restoring a
reader position or laying out a chapter. The native layer therefore consumes
all source pages in a background task and crosses the Dart/Rust bridge once
with a list. Source authors do not need a different handler shape.

Items must have stable IDs. Search pagination may overlap, so the host keeps
the first book with a given ID. Chapter and explicit paragraph IDs must remain
unique across every page of one operation; their duplicates are source errors
because UI-side deduplication would hide a broken directory cursor or parser.

## Request ownership

A request step is plain data:

```js
return {
  type: "request",
  request: {
    url: `${meta.base_url}/api/search?q=${HTML.encodeURIComponent(event.input.keyword)}`,
    method: "GET",
    headers: { Accept: "application/json" },
  },
  next_state: { stage: "results" },
};
```

The script builds the complete URL, query string included; percent-encode
values with `HTML.encodeURIComponent`.

Before sending it, Rust:

1. parses the URL and checks its host against `@access_domain`;
2. lets `login.patchRequest` attach stored authentication when supported;
3. applies a total request timeout and bounded retry policy;
4. reads the response under native body and tracing policies;
5. returns status, final URL, header pairs, and raw bytes to the reducer.

The source cannot bypass this path because it has no network primitive.

## State lifetimes

Use the narrowest state channel that matches the required lifetime:

| Lifetime | Mechanism | Typical use |
| --- | --- | --- |
| One reducer operation | `next_state` | Stage name, discovered URL, nonce, intermediate payload |
| One loaded source session | ES-module variables | Recently verified cookies, short cooldown, risk-control guard |
| Across reloads and restarts | `langhuan:storage` | Registered device, negotiated content key |
| Across result pages | `next_cursor` | Search offset, page token, directory page |

`next_state` stays a live value in the persistent feed realm, so it may carry
`Uint8Array`, `Date`, `undefined` properties, and closures. Final `result` crosses into Rust and must be JSON-compatible.

Different feeds never share a realm or storage namespace. Calls on one feed's
retained object are serialized so module state cannot be mutated concurrently.

## Authentication and verification

Authentication has two related paths:

- `login` describes a deliberate sign-in flow. The user opens the login page,
  `login.parse` extracts the minimum cookie/token data, and the host persists
  it. `login.patchRequest` applies it to later native requests.
- A reducer `webview` step handles an operation-time human gate such as a
  slider or consent page. Its snapshot returns to that operation through
  `event.webview`.

The source selects the User-Agent before navigation and must reuse the same
value in authenticated requests. The host does not need to reveal the actual
browser value back to the script.

## Cache layers

Application caches store parsed book, directory, and chapter data. They are
outside the source contract and make normal reopening fast.

Chapter-directory cache badges use a separate bulk `cached_chapter_ids` query.
It selects only stored raw chapter IDs for one source/book; it does not fetch
source content, decode paragraphs, or update cache access timestamps. Both
chapter lists share an auto-disposed provider. Completed chapter requests,
including failed refreshes, and cache maintenance invalidate affected snapshots.
A query failure remains unknown instead of being displayed as uncached.

A request step may additionally provide `cache_key` for a small in-memory,
per-source response cache. It is intended only for immutable helper assets.
The runtime stores at most eight responses, each no larger than 1 MiB, and
coalesces concurrent loads of the same key.

Do not cache a helper URL merely because it looks versioned. If a page selects
the current asset dynamically, rediscover it for each operation and omit
`cache_key`; otherwise a site rollout can leave the source using stale code.

## Reader transformers

Transformers are user settings, separate from the source's reducer exports.
Application settings define an ordered chain for all books. Book settings can
append their own chain or turn off application inheritance to use only their
own rules. Entries can be named, enabled, disabled, edited, and reordered.

The reader processes paragraphs in this order:

```text
raw source result / raw chapter cache
  -> enabled application rules (when inherited)
  -> enabled book rules
  -> reader layout and listening
```

Chinese conversion, regular-expression replacement, paragraph deletion,
first-line indentation, and chapter-title deduplication use the same chain.
No transformer is implicitly inserted before or after that chain. New settings
start with visible title-cleanup and two-character indentation entries; both can
be disabled, removed, configured, or reordered. An empty effective chain passes
source paragraphs through unchanged.

Use the **+** action to choose a transformer type and open its editor. The list
shows each rule's custom name (or its type), enabled state, and configuration
summary. Select a rule to edit its name, enabled state, and parameters on a
bottom sheet. Saving commits directly to SQLite; leaving without saving
retains the previous state. Drag the handles in the list to change the execution
order; each reorder is saved directly to SQLite. Swipe a row to delete it with
confirmation and undo, or use the single-rule editor's menu.

Application rules are managed in application settings; book rules are managed
only through the reading screen's settings. Inherited application rules also
appear in the book list. Opening one displays a notice that edits affect all
inheriting books. There is no book-detail settings action.

All rules consume and emit structured paragraphs through the same ordered
Transformer interface. Text rules modify `content`; layout rules modify
presentation metadata. First-line indentation sets `layout.first_line_indent`
to 0–8 em without adding, removing, or replacing any text. When multiple indent
rules apply, the last one wins, including zero to clear an earlier layout indent.
Source whitespace is preserved; use an explicit Regex rule if it should be removed.
Title cleanup keeps only the first title paragraph per chapter.

The layout metadata is application-generated, not a source-script field. Both
reading modes use it for measurement and rendering. Horizontal continuation pages
do not repeat first-line indentation, and the render-only placeholder does not
count toward saved UTF-16 character offsets. Listening reads the transformed
`content` directly, so layout rules do not introduce spaces into speech input.
The raw chapter cache is unchanged and does not store Transformer output.

Replacement changes every match inside each text paragraph;
deletion removes an entire paragraph if any part matches. Regex rules preserve
chapter titles unless **Also apply to chapter titles** is enabled. Images pass
through unchanged. Chinese conversion applies to both text and titles.

For example, put Simplified-to-Traditional conversion before a replacement
matching `廣告` when the source returns Simplified Chinese. Reversing the order
changes what that replacement sees. A deletion pattern such as `^.*下載.*$`
removes matching text paragraphs; replacing it with an empty string instead
retains the paragraph identity and only removes matching text.

Regex rules use Rust's `regex` syntax: `$1`, `${name}`, and `$$` in replacements
refer to numbered groups, named groups, and a literal dollar sign. Inline flags
such as `(?i)` and `(?m)` are supported; lookaround and pattern backreferences
are not. Patterns and replacements are each limited to 4096 UTF-8 bytes, regex
compilation to 1 MiB with a nesting limit of 128, and each effective chain to
64 active rules. Validation uses the same engine before saving.

Rules run after the raw cache, so edits reprocess cached content without
downloading it again or modifying the source data. Kept paragraphs retain
their IDs and comment counts. Each request captures the effective chain for
its book; there is no shared native conversion mode between books. Settings
are stored in `transformer_configurations`: one application row with null
`feed_id`/`book_id`, and one row per book with its inheritance flag and ordered
rules. Partial unique indexes enforce a single application scope and unique
book scopes; a check constraint rejects incomplete scope keys. Book settings
reference their feed, not a cached book row: cache cleanup preserves them,
while removing a feed cascades its settings. Full database backups include
this table. Migration 11 combines the former application/book Transformer
tables without re-encoding their JSON or changing rule order, names, enabled
flags, or inheritance.

Normal edits use separate application-save, book-save, and book-reset APIs.
Each transaction changes only its target scope; saving application rules also
validates the effective inherited chains, and saving a book validates it against
the application rules in the same transaction. Concurrent writes to different
scopes therefore cannot overwrite each other or bypass the combined rule limit.
Resetting a book deletes just that override and restores application inheritance.
A complete snapshot is accepted only for one-time initialization/import.
Flutter merges completed scope writes into its latest state rather than
replacing it with a snapshot captured before the write.

`FeedActor` receives its database handle during application bootstrap. It reads
the application and requested book scopes when handling `GetParagraphs`, then
builds the chapter's transform chain internally. Neither Flutter nor the API
layer supplies transformer rules with the request. SharedPreferences is
consulted only for an initial import; legacy preference keys are removed after
the database commit succeeds. Existing database settings always take precedence.

## Failure model

Expected website states return `FeedError` values, for example
`FeedError.authRequired(...)` or `FeedError.rateLimited(...)`. These become
typed application errors and can carry retry or login meaning.

Thrown exceptions represent source defects or unexpected input. Network,
policy, persistence, and sandbox failures originate in the host. See
[Error handling](../error-handling.md) for the full mapping.

## Why the architecture is structured this way

- A data-only request boundary makes domain policy enforceable.
- Persistent reducer objects make multi-step protocols practical without
  exposing a general native bridge.
- Disposable compute realms support site-supplied algorithms without granting
  them the source's authentication or storage state.
- Native HTML and crypto helpers are faster and more predictable than large
  JavaScript polyfills.
- Incremental search and finite chapter results match how the UI consumes each
  kind of data while leaving one source contract for authors.

See [Sandbox](sandbox.md) for the precise security boundary and
[API Reference](api-reference.md) for object shapes.

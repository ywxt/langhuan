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
  -> complete(items)
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
| `search` | `{ keyword }` | `items` of books and optional `next_cursor` |
| `bookInfo` | `{ bookId }` | one book in `value` |
| `chapters` | `{ bookId }` | chapter `items` and optional `next_cursor` |
| `paragraphs` | `{ bookId, chapterId }` | paragraph `items` and optional `next_cursor` |
| `login.status` | empty object | boolean `value` |

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

  return {
    type: "complete",
    items: parseDirectory(event.response.body),
  };
}
```

Reducers are synchronous. They do not return promises and cannot wait on
timers. Asynchrony exists between reducer calls, where the native host performs
the requested work.

## Pagination and result delivery

`search` can emit a page with `next_cursor`. The host calls it again only when
the UI asks for more results. This makes search incremental and cancellable.

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
    url: `${meta.base_url}/api/search`,
    method: "GET",
    params: { q: event.input.keyword },
    headers: { Accept: "application/json" },
  },
  next_state: { stage: "results" },
};
```

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
`Uint8Array`, `Date`, `undefined` properties, and closures. Final `items` and
`value` cross into Rust and must be JSON-compatible.

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

A request step may additionally provide `cache_key` for a small in-memory,
per-source response cache. It is intended only for immutable helper assets.
The runtime stores at most eight responses, each no larger than 1 MiB, and
coalesces concurrent loads of the same key.

Do not cache a helper URL merely because it looks versioned. If a page selects
the current asset dynamically, rediscover it for each operation and omit
`cache_key`; otherwise a site rollout can leave the source using stale code.

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

# Book-source API Reference

This reference describes schema 6. All source files are JavaScript ES modules
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
// @schema_version 6
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
| `access_domain` | No | One exact hostname or leftmost subdomain wildcard per line. Repeated lines form a deduplicated set. Requests to every other host—including an undeclared `base_url` host—are blocked. When no entry exists, all network requests are blocked. |
| `schema_version` | Yes | Integer contract version. It must be `6` for this runtime. |

Exact IP hosts are accepted for development. Domain entries cannot contain a
scheme, port, path, credentials, or wildcard outside the leftmost `*.` label.
Metadata uses `@key value`, without a colon after the key. For example,
`@schema_version: 6` is rejected with a syntax hint and its line number.

Unknown metadata keys and duplicate scalar keys are rejected with their line
number. Only `access_domain` is repeatable.

The frozen global `meta` contains `id`, `name`, `version`, `author`,
`description`, `base_url`, `access_domains`, and `schema_version`.

## Feed object

```ts
type Feed = {
  search(event: Event): Step;
  bookInfo(event: Event): Step;
  chapters(event: Event): Step;
  paragraphs(event: Event): Step;
  comments?: Comments | null;
  login?: Login;
};
```

All four content handlers are required synchronous functions.

| Handler | Parameter | Host behaviour |
| --- | --- | --- |
| `search` | One `Event` with `input.keyword` | Called page by page. A completion with `next_cursor` allows the host to request another page; without it the stream ends. If pages overlap, the host keeps the first result for each book ID. |
| `bookInfo` | One `Event` with `input.bookId` | Must eventually complete with one valid `Book` in `result`. Pagination is not used. |
| `chapters` | One `Event` with `input.bookId` | May paginate with `next_cursor`; the host concatenates pages and rejects duplicate chapter IDs. |
| `paragraphs` | One `Event` with `input.bookId` and `input.chapterId` | May paginate with `next_cursor`; the host concatenates pages and assigns indices to paragraphs without explicit IDs. |
| `comments` | Optional [`Comments`](#comments-read-only) object | Exposes read-only chapter and paragraph comments, including existing replies. Support is detected from the exported handlers. |
| `login` | Optional `Login` object | Enables interactive sign-in and authenticated request patching. Partial login implementations are rejected at source load. |

A handler must return a step object before the JavaScript deadline. Returning a
Promise or using top-level `await` is unsupported.

## Event

```ts
type Event = {
  operation: "search" | "bookInfo" | "chapters" | "paragraphs" | "login.status" | "comments.chapter" | "comments.paragraph";
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
| `operation` | Canonical exported handler name (for example `bookInfo` or `login.status`). It is stable for every round of one operation. |
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
| `bookInfo` | `bookId: string` | Source-owned stable book ID selected from search/bookshelf data. |
| `chapters` | `bookId: string` | Source-owned stable book ID. |
| `paragraphs` | `bookId: string`, `chapterId: string` | IDs of the requested book and chapter. |
| `login.status` | No fields | Login-status probe invoked through `login.status`. |
| `comments.chapter` | [`ChapterCommentsInput`](#chapter-comments-input) | Chapter comments or replies to a chapter comment. |
| `comments.paragraph` | [`ParagraphCommentsInput`](#paragraph-comments-input) | Paragraph comments or replies to a paragraph comment. |

### Chapter comments input

```ts
type ChapterCommentsInput = {
  bookId: string;
  chapterId: string;
  parentId?: string | null;
};
```

| Field | Required | Behaviour |
| --- | :---: | --- |
| `bookId` | Yes | Source-owned book ID. |
| `chapterId` | Yes | Source-owned chapter ID within the book. |
| `parentId` | No | Omitted or `null` selects top-level comments. A previously returned comment ID selects that comment's existing replies. It does not create a reply. |

### Paragraph comments input

```ts
type ParagraphCommentsInput = ChapterCommentsInput & {
  paragraphId: string;
};
```

`bookId`, `chapterId`, and `parentId` have the same meaning as in
[`ChapterCommentsInput`](#chapter-comments-input).

| Field | Required | Behaviour |
| --- | :---: | --- |
| `paragraphId` | Yes | Original source paragraph ID, extracted from the host's typed paragraph identity. Transform descendant paths are not passed to the source. Paragraphs with generated IDs have no paragraph-comment action. |

Pagination belongs to `Event.cursor`, not either input type. The first page has
`cursor: null`; later pages receive the previous top-level `next_cursor`
unchanged. Each comment or reply list owns its cursor. `Event.state` starts as
`undefined` for each page and carries only that page's intermediate steps.

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
  headers?: Record<string, string>;
  body?: Uint8Array;
};
```

`cache_key` must be non-empty and at most 128 bytes to enable the helper
response cache. Only status-200 responses up to 1 MiB are stored.

| Field | Required | Value and behaviour |
| --- | :---: | --- |
| `type` | Yes | Must be the exact string `"request"`. |
| `request.url` | Yes | Absolute URL including its query string. The script builds the complete URL itself; encode it with [`HTML.encodeURIComponents`](#namespace-functions), which turns `[key, value]` pairs into a `k=v&k=v` query string. The native host validates the hostname against `access_domain` after auth patching and before network access. A `params` field is rejected — query strings belong in the URL. |
| `request.method` | No | HTTP method string; defaults to `GET` when omitted. Invalid method syntax is rejected before the request is sent. |
| `request.headers` | No | String-to-string map. Arrays and non-string values are rejected. Response header pairs are a separate representation that preserves repeated Set-Cookie fields. |
| `request.body` | No | `Uint8Array` is sent byte-for-byte. Encode text explicitly with `TextEncoder.encode(text)`. Strings and other values are rejected. Omission means no body. |
| `next_state` | No | Live value delivered as `event.state` after the request. `null` and `undefined` mean no state. |
| `cache_key` | No | Per-source helper-response key. Empty keys and keys longer than 128 UTF-8 bytes are rejected. A hit skips HTTP but still produces `event.response`. |

Before HTTP, `login.patchRequest` may return a modified request. Transient
native failures use the host retry policy without invoking the reducer between
attempts. A request step consumes one of the operation's sixteen internal
steps.

### `compute`

```ts
type ComputeStep = {
  type: "compute";
  programs: string[];
  input?: unknown;       // omission preserves undefined
  next_state?: unknown;
};
```

Each string is an ES module. Programs run in order in one fresh compute realm;
the last module's default export becomes `event.compute`.

| Field | Required | Value and behaviour |
| --- | :---: | --- |
| `type` | Yes | Must be `"compute"`. |
| `programs` | Yes | Array of 1–8 source strings, at most 4 MiB in total. Each is evaluated as an ES module in order. The last program must default-export a defined value. |
| `input` | No | Realm-independent value installed as compute global `input`; omission preserves `undefined`. Supports plain data, `undefined`, and `Uint8Array`, but not functions or host objects. |
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
| `url` | Yes | Initial absolute URL opened by the platform WebView. Its hostname must match `access_domain`; an empty allowlist blocks the step before the browser opens. |
| `user_agent` | Yes | User-Agent applied before first navigation; must be non-empty, contain no control characters, and be at most 512 bytes. Reuse it in later requests. |
| `title` | No | User-facing title for the browser page. |
| `next_state` | No | Value returned through `event.state` with the snapshot. |

Cancellation, lack of a WebView host, or an incomplete flow produces an
authentication-required error. A WebView step consumes one internal step.

### `complete`

```ts
type CompleteStep = {
  type: "complete";
  result: unknown;
  next_cursor?: unknown;
};
```

`result` is required. It is the sole operation payload; there are no top-level
`items` or `value` fields. `next_cursor` remains a sibling of
`result`, not part of it.

| Field | Required | Value and behaviour |
| --- | :---: | --- |
| `type` | Yes | Must be `"complete"`. |
| `result` | Yes | Search, chapters, paragraphs and comments return an array; `bookInfo` returns a book object; `login.status` returns a boolean. Missing or `undefined` is an error. An empty page must explicitly return an empty array. Each page is capped before any item flows: search and comments at most 200 items, chapters at most 10,000, paragraphs at most 2,000. Item and field limits are documented per model below. |
| `next_cursor` | No | JSON token for another page. `null`/`undefined` ends pagination. It becomes the next page's `event.cursor`. Bytes, functions and other non-JSON values are rejected. The token is limited to 4,096 encoded bytes and must differ from the page's `event.cursor`: the host fails a page that repeats it, and automatically followed pagination stops at 1,000 pages. Single-value operations do not paginate. |

Results and cursors must be JSON-compatible. Results are capped at 16 MiB;
`Uint8Array`, `BigInt`, cycles and unsupported host objects are rejected.
Explicit `null` is preserved and validated by the operation's result model.
Array `undefined` slots become `null`; object properties with `undefined` are
omitted, following JSON conversion semantics.

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

A search page holds at most 200 items; the same object returned by
`bookInfo` is validated the same way.

| Field | Required | Behaviour |
| --- | :---: | --- |
| `id` | Yes | Source-owned book identity. It must be non-empty, at most 4,096 UTF-8 bytes, and remain stable when title/author changes. When pagination repeats an ID, the host keeps its first occurrence. |
| `title` | Yes | Display title, at most 1,024 UTF-8 bytes. |
| `author` | Yes | Display author at most 1,024 UTF-8 bytes; use an explicit fallback string when the site omits it. |
| `cover_url` | No | Absolute or site-usable cover URL, or `null`; at most 8,192 UTF-8 bytes. It is consumed by the application image loader rather than a reducer request. |
| `description` | No | Plain-text synopsis at most 32,768 UTF-8 bytes, or `null`. Do not return raw page HTML. |

The same shape is used by search results and `bookInfo` completion `result`.

### Chapter

```ts
type Chapter = { id: string; title: string };
```

A directory page holds at most 10,000 entries.

| Field | Required | Behaviour |
| --- | :---: | --- |
| `id` | Yes | Stable source-owned chapter identity, unique across the complete paginated directory. It must be non-empty, at most 4,096 UTF-8 bytes, and is later returned as `input.chapterId`. |
| `title` | Yes | User-facing chapter title in directory order, at most 1,024 UTF-8 bytes. |

### Paragraph

```ts
type Paragraph =
  | { type: "title"; id?: string; text: string; comment_count?: number | null }
  | { type: "text"; id?: string; content: string; comment_count?: number | null }
  | { type: "image"; id?: string; url: string; alt?: string | null; comment_count?: number | null };
```

Book and chapter IDs are required and stable. Repeated search-book IDs are
discarded after their first occurrence because remote search pagination can
overlap. Chapter IDs remain strictly unique across all pages of one operation.
Paragraph IDs are optional; the host assigns sequential indices
when omitted.

A chapter page holds at most 2,000 paragraphs. An explicit `id` is optional but
must be non-empty and at most 4,096 UTF-8 bytes when given.

| Variant | Fields and behaviour |
| --- | --- |
| `title` | `text` is the chapter/section heading, at most 1,024 UTF-8 bytes. Optional `id` supplies the original source identity instead of a generated identity. Optional `comment_count` is the paragraph-comment total for this unit (the chapter as a whole for a title). |
| `text` | `content` is one plain-text paragraph at most 32,768 UTF-8 bytes. Do not include HTML tags. Optional `id` supplies the original source identity instead of a generated identity. Optional `comment_count` is the paragraph-comment total for this paragraph. |
| `image` | `url` identifies the image and must be non-empty, at most 8,192 UTF-8 bytes; optional `alt` is accessible fallback text at most 2,048 UTF-8 bytes and defaults to `null`. Optional `id` supplies the original source identity instead of a generated identity. Optional `comment_count` is the paragraph-comment total for this image. |

`comment_count` is an unsigned integer (0–4,294,967,295). Omitted or `null`
means unknown or unsupported; a number means known, where `0` is supported
with no comments. It is only meaningful together with `id` — the host ignores
it on generated-identity paragraphs because a comment count is useless
without an addressable comment thread.

Host-assigned indices continue across paginated paragraph pages. Explicit IDs
are strings and should only be used when the site exposes a stable identity.

After parsing, the host wraps the ID as a typed original identity plus a
transform descendant path. Text conversion preserves the original ID, and
splitting only changes the path. Numeric strings remain source IDs; they are
never interpreted as host indices. Paragraph comments receive the original
source ID, not the descendant path or visible paragraph position.

### Comment author

```ts
type CommentAuthor = {
  name: string;
  avatar_url?: string | null;
};
```

| Field | Required | Behaviour |
| --- | :---: | --- |
| `name` | Yes | Display name, at most 1,024 UTF-8 bytes. |
| `avatar_url` | No | Avatar URL or `null`, at most 8,192 UTF-8 bytes. The UI shows it as a circular avatar; a default icon is displayed when it is absent or fails to load. |

### Comment replies

```ts
type CommentReplies = {
  total_count?: number | null;
};
```

| Field | Required | Behaviour |
| --- | :---: | --- |
| `total_count` | No | Number of existing replies as an unsigned 32-bit integer (0–4,294,967,295). Omitted or `null` means unknown, not zero. |

This object describes a readable reply collection. Its presence enables the
replies action even when the count is unknown. The replies themselves are read
through the same comment handler using `parentId`; they are not embedded here.

### Comment

```ts
type Comment = {
  id: string;
  author: CommentAuthor;
  text: string;
  created_at_ms?: number | null;
  like_count?: number | null;
  replies?: CommentReplies | null;
};
```

| Field | Required | Behaviour |
| --- | :---: | --- |
| `id` | Yes | Non-empty stable comment ID, at most 4,096 UTF-8 bytes. IDs are scoped to their comment or reply collection. The UI keeps the first occurrence when pages overlap. |
| `author` | Yes | [`CommentAuthor`](#comment-author) describing the displayed author. |
| `text` | Yes | Plain text, at most 32,768 UTF-8 bytes. It is never executed as HTML. |
| `created_at_ms` | No | Unix milliseconds as an integer from 0 through 8,640,000,000,000,000, or `null`. Omitted means unknown. |
| `like_count` | No | Unsigned 32-bit count (0–4,294,967,295) or `null`. Omitted means unknown. Display only; no like action. |
| `replies` | No | [`CommentReplies`](#comment-replies) enables reading this comment's existing replies. Absent or `null` hides that action. Opening it passes this comment's `id` as `parentId`. |

The same model represents top-level comments and replies. It carries no posting,
liking, or other mutation operation.

### Comment result

The `result` of a comments operation's [`complete`](#complete) step is the
array of [`Comment`](#comment) objects itself — at most 200 per website page:

```ts
result: Comment[];
```

An empty array does not by itself end pagination. The pagination token is the
step's sibling `next_cursor`, never a field of the result.

## Comments (read-only)

```ts
type Comments = {
  chapter?: ((event: Event & { input: ChapterCommentsInput }) => Step) | null;
  paragraph?: ((event: Event & { input: ParagraphCommentsInput }) => Step) | null;
};
```

Either handler, or the entire `comments` object, may be absent or `null`.
This means unsupported. Other non-function handler values fail source loading.
The host detects support from exports without executing them. An empty result
array means supported with no results.

These functions read existing comments and replies. They do not expose posting,
liking, voting, purchasing, or other remote mutations. There is no sort option;
the source uses the website's default order.

### `comments.chapter(event)`

| Parameter | Type | Behaviour |
| --- | --- | --- |
| `event` | [`Event`](#event) with [`ChapterCommentsInput`](#chapter-comments-input) | Uses operation `comments.chapter`. Reads chapter comments, or existing replies when `input.parentId` is set. Paragraph identity is not used. |

Return a normal [`Step`](#steps). Eventually complete with the
[`Comment`](#comment) array in `result` and an optional top-level
`next_cursor`. Each completed operation returns one website page; the host does
not automatically drain the collection.

### `comments.paragraph(event)`

| Parameter | Type | Behaviour |
| --- | --- | --- |
| `event` | [`Event`](#event) with [`ParagraphCommentsInput`](#paragraph-comments-input) | Uses operation `comments.paragraph`. Reads comments on the selected original paragraph, or existing replies when `input.parentId` is set. |

Return a normal [`Step`](#steps), completing with the same
[`Comment`](#comment) array as `comments.chapter`. Reply queries retain
`input.paragraphId` and use independent cursors; they do not introduce another
operation name.

### Pagination and failures

The usual `request`, `compute`, `webview`, and `fail` steps apply. The host
patches authentication and enforces domain and resource limits. Comment requests
bypass the source's `cache_key` response cache.

`next_cursor` is a JSON token limited to 4,096 encoded bytes. Omitted or `null`
ends the collection; an empty result page may still have a next cursor. The host
and UI reject unchanged or cyclic cursors. A reply list does not share its cursor
with its parent list or other reply lists.

Invalid types and exceeded limits fail the page rather than silently truncating
it. The UI retains displayed comments and retries the failed page. Refresh starts
a new session; closing the panel cancels in-flight work. Developer tools and the
Agent API run the same operations either as a pipeline that follows `next_cursor`
to the end of the thread, or one page at a time with explicit `input` and
`cursor`.

### Example

This completion contains one `Comment` with a `CommentReplies` descriptor:

```js
return {
  type: "complete",
  result: [{
    id: "c7",
    author: { name: "Reader", avatar_url: null },
    text: "An interesting paragraph.",
    created_at_ms: null,
    like_count: 12,
    replies: { total_count: 3 },
  }],
  next_cursor: { page: 2 },
};
```

To read this comment's replies, call the same handler with `parentId: "c7"` and
`cursor: null`. Continue that reply list with its own returned `next_cursor`.

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

Patch and return the request. The request contains normalized `method` and
`headers`; an existing body is a `Uint8Array`.

| Parameter | Behaviour |
| --- | --- |
| `operation` | Fresh `{ operation, input }` descriptor for the request's current content/auth-status operation. Use it to scope credentials or headers without duplicating IDs in state. |
| `request` | Mutable request object constructed from the reducer step. `method` is always present, `headers` is an object, and `body` is absent or a byte array. Edit `request.url` directly — with `encodeURIComponent`-style helpers from [`langhuan:html`](#langhuanhtml) — when a credential belongs in the query string. |
| `auth` | Persisted JSON value returned by `parse`. |

The function runs synchronously for every native request, including each
request in a multi-step operation. It must return a complete valid `Request`;
returning `undefined` or a malformed object fails the operation. The returned
URL is still checked against the allowlist, so auth cannot widen network access.

### `login.status(event)`

Optional reducer with operation `login.status`. Its `event.input` is empty and
normal request/compute/WebView steps are available. Complete with boolean
`result`: `true` means logged in and `false` means the stored auth has expired.
When no auth is stored, the host reports logged out without calling this hook.
When stored auth exists but `status` is omitted, the host assumes it is logged
in rather than probing the website.

## Globals

### `FeedError`

```js
FeedError.authRequired(message)           // code: auth_required
FeedError.verificationRequired(message)   // code: verification_required
FeedError.rateLimited(message)            // code: rate_limited
FeedError.contentNotFound(message)        // code: content_not_found
FeedError.sourceUnavailable(message)      // code: source_unavailable
FeedError.raise(code, message)
```

Every helper converts `message` with `String(message)` and returns a new
`FailStep`; it does not throw. `raise` also converts `code` to a string.

| Helper | Host meaning |
| --- | --- |
| `authRequired` | Missing/expired credentials; non-retryable without user action. |
| `verificationRequired` | Human/anti-bot challenge; non-retryable as an ordinary HTTP request. |
| `rateLimited` | Temporary throttling; classified as retryable. |
| `contentNotFound` | Missing or inaccessible content; non-retryable. |
| `sourceUnavailable` | Temporary source outage; classified as retryable. |
| `raise` | Custom expected code; preserved but non-retryable. |

### Globals and explicit imports

The feed realm exposes only the host's frozen `meta` and `FeedError` objects
in addition to QuickJS language built-ins. There are no browser aliases,
no-op consoles, fake timers, or global base64 shims. Import `Bytes`,
`TextEncoder` and `TextDecoder` from `langhuan:encoding` for conversions.
A third-party compute program must explicitly supply the environment it
requires inside its isolated compute realm.

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
decoder.decode(data: Uint8Array): string;
```

#### Constructor parameters

| Parameter | Type | Default | Behaviour |
| --- | --- | --- | --- |
| `label` | `string` | `"utf-8"` | Selects the character encoding. Labels are resolved with WHATWG aliases, so values such as `utf8`, `gbk`, `big5`, and `shift_jis` are accepted. An unknown label throws. |
| `options.fatal` | `boolean` | `false` | When `false`, malformed byte sequences are replaced during decoding. When `true`, the first malformed sequence throws instead. A non-boolean value throws. |
| `options.ignoreBOM` | `boolean` | `false` | When `false`, a leading BOM for the selected encoding is removed. When `true`, BOM removal is disabled and the decoded BOM remains in the returned string. A non-boolean value throws. |

The read-only properties expose the normalized encoding name and the two
constructor flags.

#### `decoder.decode(data)`

| Parameter | Type | Behaviour |
| --- | --- | --- |
| `data` | Required `Uint8Array` | Decodes the complete byte array using the constructor's encoding and options. Other types, omitted input and additional arguments are rejected. |

Every call is independent. There is no streaming decode option or retained
partial state; join response fragments before decoding.

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
HTML.encodeURIComponent(value: string, charset?: string): string;
HTML.encodeURIComponents(pairs: [string, string][], charset?: string): string;

document.find(selector: string): Selection;

// A Selection is a real Array of nodes (length, indices, map, for...of, …)
// with jQuery traversal methods mixed in.
selection.length: number;
selection[index]: Node;
selection.first(): Node | undefined;
selection.last(): Node | undefined;
selection.eq(index: number): Node | undefined;
selection.each(fn: (index: number, node: Node) => boolean | void): Selection;
selection.text(): string;
selection.attr(name: string): string | undefined;
selection.attrs(): Record<string, string>;
selection.html(): string | undefined;
selection.outerHTML(): string | undefined;
selection.find(selector: string): Selection;
selection.parent(selector?: string): Selection;
selection.children(selector?: string): Selection;
selection.closest(selector: string): Selection;

node.tagName: string;                     // uppercased, like Element.tagName
node.text(): string;
node.attr(name: string): string | undefined;
node.attrs(): Record<string, string>;
node.html(): string | undefined;
node.outerHTML(): string | undefined;
node.find(selector: string): Selection;
node.parent(): Node | undefined;
node.children(): Selection;
node.closest(selector: string): Node | undefined;
```

The interface follows jQuery and the browser's native DOM surface: selections
are real arrays carrying jQuery traversal methods, and nodes follow browser
element semantics (`tagName` uppercased, `attr` returning `""` for an empty
attribute, `closest` walking ancestor-or-self). The parser is read-only and
backed by Rust `scraper`; none of these objects can modify the document.

### Namespace functions

| Function | Parameters | Return and behaviour |
| --- | --- | --- |
| `HTML.parse` | `input: string` | Parses one HTML document and returns a `Document`. Empty/blank input, non-string input, or input larger than 4 MiB throws. |
| `HTML.decodeEntities` | `input: string` | Parses the input as an HTML fragment and returns its text, decoding entities. Input larger than 4 MiB throws. |
| `HTML.encodeURIComponent` | `value: string`, `charset?: string` | Percent-encodes `value` exactly like the browser's `encodeURIComponent`: alphanumeric characters and `-_.!~*'()` stay unescaped. The optional `charset` selects the byte encoding via WHATWG labels (`"gbk"`, `"big5"`, …) and defaults to UTF-8 — `HTML.encodeURIComponent("你好", "gbk")` returns `"%C4%E3%BA%C3"`. An unknown label throws. |
| `HTML.encodeURIComponents` | `pairs: [string, string][]`, `charset?: string` | Builds a whole query string from `[key, value]` pairs: both sides are percent-encoded like components and the pairs joined with `&` — `HTML.encodeURIComponents([["q", "a b"], ["page", "2"]])` returns `"q=a%20b&page=2"` and the empty array returns `""`. The optional `charset` behaves as in `HTML.encodeURIComponent`. Use it to build query strings, since requests carry full URLs. Keys and values must be strings; anything else throws. |

### Document methods

Every selector parameter is a CSS selector string. Invalid syntax throws.

| Method | Return and behaviour |
| --- | --- |
| `find(selector)` | Returns every matching element in document order. |

Selectors support tags, `#id`, `.class`, descendant and child combinators,
comma groups, and attribute operators `=`, `*=`, `^=`, `$=`, `~=`, and `|=`.

### Selection methods

A `Selection` is a real JavaScript `Array` of nodes: `length`, numeric
entries, and the full `Array` prototype (`map`, `filter`, `for...of`, spread)
all work. The jQuery-style methods below are mixed in.

| Method | Parameters | Return and behaviour |
| --- | --- | --- |
| `first()` | None | First node or `undefined` for an empty selection. |
| `last()` | None | Last node or `undefined`. |
| `eq(index)` | `index: number` | Node at `index`; negative counts backwards from the end like jQuery's `eq`. Out-of-range indices return `undefined`. |
| `each(fn)` | `fn: (index, node)` | Calls `fn` with `this` bound to the node, jQuery-style; returning `false` stops the iteration. Returns the selection. |
| `text()` | None | Concatenated text of every selected node in order. `<br>` becomes `\n`; `script` and `style` content is skipped, like `innerText`. |
| `attr(name)` | `name: string` | Attribute from the first node. An empty attribute returns `""`; only an absent attribute returns `undefined`, like `getAttribute`. |
| `attrs()` | None | New attribute map for the first node, or an empty object. |
| `html()` | None | Inner HTML of the first node, or `undefined`. |
| `outerHTML()` | None | Outer HTML of the first node, or `undefined`. |
| `find(selector)` | `selector: string` | Matching descendants of all selected roots. |
| `parent(selector?)` | `selector?: string` | Immediate parent elements of the selected nodes, optionally filtered by selector. |
| `children(selector?)` | `selector?: string` | Direct child elements, optionally filtered; text nodes are excluded. |
| `closest(selector)` | `selector: string` | Nearest ancestor-or-self element of each selected node matching the selector. |

Traversal results merged from several roots are deduplicated and ordered by
document position, like jQuery's `uniqueSort`.

### Node properties and methods

| Member | Parameters | Return and behaviour |
| --- | --- | --- |
| `tagName` | — | Element name uppercased, like the browser's `Element.tagName`. |
| `text()` | None | Descendant text using the same `<br>`, `script`, and `style` rules as selection text. |
| `attr(name)` | `name: string` | Attribute value; `""` for an empty attribute and `undefined` only when absent. |
| `attrs()` | None | New object containing every attribute. |
| `html()` | None | Inner HTML. |
| `outerHTML()` | None | Outer HTML. |
| `find(selector)` | `selector: string` | Matching descendants of this node. |
| `parent()` | None | Nearest parent element or `undefined`. |
| `children()` | None | Selection of direct child elements; text nodes are excluded. |
| `closest(selector)` | `selector: string` | Nearest ancestor-or-self element matching the selector, or `undefined`. |

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
storage backend. The reading app installs a persistent backend; the
developer tools install a session-scoped in-memory one (see
[Developer tools](../feed-debug-tools.md)).

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

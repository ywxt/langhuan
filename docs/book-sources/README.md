# Book Source Scripting Guide

Book sources are Lua scripts that tell Langhuan how to fetch novel content from a specific website.

## Files in This Directory

- [`biquge-tw.lua`](biquge-tw.lua) — A complete feed source for biquge.tw.
- [`login-handler-example.lua`](login-handler-example.lua) — A template snippet demonstrating the login flow hooks.
- [`../error-handling.md`](../error-handling.md) — Error handling API for the `@langhuan/error` module.

## Script Header

Every script starts with a metadata block wrapped in `==Feed==` markers:

```lua
-- ==Feed==
-- @id           my-source
-- @name         My Book Source
-- @version      1.0.0
-- @author       Your Name
-- @description  A brief description of this source
-- @base_url     https://example.com
-- @access_domain example.com
-- @access_domain m.example.com
-- @schema_version 1
-- ==/Feed==
```

| Field             | Type      | Required | Description                                                                                                                               |
| ----------------- | --------- | -------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `@id`             | `string`  | Yes      | Unique identifier for the source                                                                                                          |
| `@name`           | `string`  | Yes      | Display name                                                                                                                              |
| `@version`        | `string`  | Yes      | Version string (e.g. `"1.0.0"`)                                                                                                           |
| `@author`         | `string`  | No       | Script author                                                                                                                             |
| `@description`    | `string`  | No       | Brief description                                                                                                                         |
| `@base_url`       | `string`  | Yes      | Base URL of the target site                                                                                                               |
| `@access_domain`  | `string`  | No       | Allowed domain(s) for HTTP requests. Repeatable — one per line. If any are specified, all HTTP requests are restricted to these hostnames |
| `@schema_version` | `integer` | Yes      | Schema version (currently `1`)                                                                                                            |

The runtime injects a read-only global `meta` table containing these header fields (e.g. `meta.id`, `meta.base_url`, `meta.access_domains`).

## Lua Sandbox

Each book source runs in an **isolated, sandboxed Lua 5.4 VM**. The sandbox is designed to allow text processing and data extraction while preventing any direct system access.

### Enabled Standard Libraries

| Library     | Description                                                                    |
| ----------- | ------------------------------------------------------------------------------ |
| `string`    | String manipulation (`string.find`, `string.match`, `string.gsub`, etc.)       |
| `table`     | Table manipulation (`table.insert`, `table.remove`, `table.sort`, etc.)        |
| `math`      | Math functions (`math.min`, `math.max`, `math.floor`, etc.)                    |
| `utf8`      | UTF-8 support (`utf8.len`, `utf8.codes`, etc.)                                 |
| `coroutine` | Coroutine support                                                              |
| `os`        | Partially enabled. Date/time helpers like `os.date`, `os.time`, `os.difftime`. |

Base functions that can dynamically execute code are disabled: `load`, `loadfile`, `loadstring`, `dofile`.

### Disabled / Restricted Standard Libraries

| Library / API | Restriction                                                                                                                        | Reason                                                         |
| ------------- | ---------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| `os`          | Partially enabled only. `os.execute`, `os.exit`, `os.getenv`, `os.remove`, `os.rename`, `os.tmpname`, `os.setlocale` are disabled. | Prevent command execution, env access, and filesystem mutation |
| `io`          | Completely disabled                                                                                                                | No filesystem access                                           |
| `debug`       | Completely disabled                                                                                                                | No debug introspection                                         |
| `package`     | Completely disabled (custom `require` is used)                                                                                     | No arbitrary module loading                                    |

### Built-in Modules

The standard `require` is replaced with a sandboxed version that only resolves `@langhuan/*` modules. Attempting to require anything else will raise an error.

#### `@langhuan/html`

HTML parsing module powered by the Rust `scraper` crate. Provides three types: `Document`, `NodeList`, and `Element`.

```lua
local html = require("@langhuan/html")
```

**Module functions:**

| Function       | Parameters         | Returns    | Description                                           |
| -------------- | ------------------ | ---------- | ----------------------------------------------------- |
| `html.parse()` | `html_str: string` | `Document` | Parse an HTML string. Errors if input is empty/blank. |

**Document:**

| Method         | Parameters         | Returns    | Description                                  |
| -------------- | ------------------ | ---------- | -------------------------------------------- |
| `doc:select()` | `selector: string` | `NodeList` | Select all elements matching a CSS selector. |

**NodeList:**

| Method / Operator   | Parameters         | Returns          | Description                                                            |
| ------------------- | ------------------ | ---------------- | ---------------------------------------------------------------------- |
| `#list`             | —                  | `integer`        | Number of elements in the list.                                        |
| `list[i]`           | `i: integer`       | `Element \| nil` | 1-based index access. Returns `nil` for out-of-bounds.                 |
| `list:first()`      | —                  | `Element \| nil` | First element, or `nil` if empty.                                      |
| `list:text()`       | —                  | `string`         | Concatenated text of all elements (whitespace normalized).             |
| `list:attr()`       | `name: string`     | `string \| nil`  | Attribute value from the first element only.                           |
| `list:attrs()`      | —                  | `table`          | All attributes of the first element as `{ key = value, ... }`.         |
| `list:html()`       | —                  | `string \| nil`  | Inner HTML of the first element, or `nil` if empty.                    |
| `list:outer_html()` | —                  | `string \| nil`  | Outer HTML of the first element, or `nil` if empty.                    |
| `list:select()`     | `selector: string` | `NodeList`       | Select descendants matching selector from all elements (deduplicated). |

**Element:**

| Method              | Parameters         | Returns         | Description                                   |
| ------------------- | ------------------ | --------------- | --------------------------------------------- |
| `elem:text()`       | —                  | `string`        | Text content (whitespace normalized).         |
| `elem:attr()`       | `name: string`     | `string \| nil` | Attribute value by name.                      |
| `elem:attrs()`      | —                  | `table`         | All attributes as `{ key = value, ... }`.     |
| `elem:html()`       | —                  | `string`        | Inner HTML.                                   |
| `elem:outer_html()` | —                  | `string`        | Outer HTML (includes the element's own tags). |
| `elem:select()`     | `selector: string` | `NodeList`      | Select descendants matching a CSS selector.   |

**Example:**

```lua
local html = require("@langhuan/html")
local doc = html.parse("<html>...</html>")

-- CSS selector → node list
local nodes = doc:select("h1.title")

for i = 1, #nodes do
    local node = nodes[i]
    print(node:text())           -- inner text
    print(node:attr("href"))     -- attribute value
    print(node:html())           -- inner HTML
end

-- First match
local first = nodes:first()

-- Chain selectors
local links = doc:select("div.content"):select("a")

-- All attributes
local attrs = first:attrs()     -- { class = "title", id = "main" }
```

#### `@langhuan/error`

Structured error reporting module. Lets scripts raise **expected errors** (login required, Cloudflare challenge, rate limiting, etc.) that the Flutter UI can act on — as opposed to plain `error()` which is treated as a script bug.

```lua
local err = require("@langhuan/error")
```

| Function                          | Parameters              | Description                              |
| --------------------------------- | ----------------------- | ---------------------------------------- |
| `err.auth_required(message)`      | `message: string`       | Login is required to proceed             |
| `err.cf_challenge(message)`       | `message: string`       | Cloudflare / anti-bot challenge detected |
| `err.rate_limited(message)`       | `message: string`       | Too many requests; try again later       |
| `err.content_not_found(message)`  | `message: string`       | The requested content does not exist     |
| `err.source_unavailable(message)` | `message: string`       | The source is temporarily down           |
| `err.raise(code, message)`        | `code, message: string` | Custom error code                        |

For full details, error code semantics, and examples, see the [Error Handling Guide](../error-handling.md).

#### `@langhuan/json`

JSON encoding/decoding module.

```lua
local json = require("@langhuan/json")
```

| Function        | Parameters    | Returns  | Description                                                      |
| --------------- | ------------- | -------- | ---------------------------------------------------------------- |
| `json.decode()` | `str: string` | `any`    | Parse a JSON string into a Lua value. JSON `null` → Lua `nil`.   |
| `json.encode()` | `value: any`  | `string` | Serialize a Lua value to a JSON string. Lua `nil` → JSON `null`. |

**Example:**

```lua
local json = require("@langhuan/json")

local data = json.decode('{"key": "value", "list": [1, 2, 3]}')
print(data.key)       -- "value"
print(data.list[1])   -- 1

local str = json.encode({ key = "value", list = {1, 2, 3} })
```

### Network Access

Scripts **cannot** access the network directly. Instead, scripts return HTTP request descriptors (url, method, headers, params, body), and the Rust runtime executes them via `reqwest`. The response is then passed back to the script's `parse` function. Only domains listed in `@access_domain` are allowed.

### Isolation

Each feed gets its own Lua VM instance. Scripts cannot interfere with each other or access any shared state.

## Common Types

### `HttpRequest`

Return value of all `*.request` functions. Describes an HTTP request for the runtime to execute.

| Field     | Type                    | Required | Default | Description                           |
| --------- | ----------------------- | -------- | ------- | ------------------------------------- |
| `url`     | `string`                | Yes      | —       | Target URL                            |
| `method`  | `string`                | No       | `"GET"` | HTTP method (`"GET"`, `"POST"`, etc.) |
| `params`  | `table<string, string>` | No       | `{}`    | Query parameters appended to the URL  |
| `headers` | `table`                 | No       | `{}`    | HTTP headers (see below)              |
| `body`    | `string`                | No       | `nil`   | Raw request body (for POST/PUT)       |

Headers accept two forms:

```lua
-- Map form
headers = { ["Content-Type"] = "application/json" }

-- Array-of-pairs form
headers = { {"Content-Type", "application/json"} }
```

### `HttpResponse`

Passed to all `*.parse` functions as the `resp` parameter.

| Field          | Type                      | Description                                        |
| -------------- | ------------------------- | -------------------------------------------------- |
| `resp.status`  | `integer`                 | HTTP status code (e.g. `200`)                      |
| `resp.headers` | `{{string, string}, ...}` | Response headers as array of `{name, value}` pairs |
| `resp.body`    | `string`                  | Raw response body                                  |
| `resp.url`     | `string`                  | Final URL after redirects                          |

### `Page`

Generic pagination wrapper returned by paginated `*.parse` functions.

| Field         | Type           | Description                                                                                                                                                  |
| ------------- | -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `items`       | `{T, ...}`     | Array of result items (type depends on handler)                                                                                                              |
| `next_cursor` | `any` or `nil` | `nil` = last page. Any non-nil value is passed back as the `cursor` argument to the next `*.request` call. Can be a number, string, table, or any Lua value. |

## Required Functions

The script must return a table with four entries: `search`, `book_info`, `chapters`, and `paragraphs`. Each entry is a table with `request` and `parse` functions.

### `search.request(keyword, cursor)`

Build the HTTP request for a search query.

| Parameter | Type           | Description                                                                          |
| --------- | -------------- | ------------------------------------------------------------------------------------ |
| `keyword` | `string`       | Search query text                                                                    |
| `cursor`  | `any` or `nil` | `nil` on the first page; the previous page's `next_cursor` value on subsequent pages |

Returns: [`HttpRequest`](#httprequest)

### `search.parse(resp)`

Parse the HTTP response into search results.

| Parameter | Type                            | Description       |
| --------- | ------------------------------- | ----------------- |
| `resp`    | [`HttpResponse`](#httpresponse) | The HTTP response |

Returns: [`Page`](#page) of `SearchResult`:

| Field         | Type     | Required | Description      |
| ------------- | -------- | -------- | ---------------- |
| `id`          | `string` | Yes      | Book identifier  |
| `title`       | `string` | Yes      | Book title       |
| `author`      | `string` | Yes      | Author name      |
| `cover_url`   | `string` | No       | Cover image URL  |
| `description` | `string` | No       | Book description |

Book IDs must be unique within a single search result stream. The runtime validates this and returns an error when a duplicate ID is encountered.

### `book_info.request(book_id)`

Build the HTTP request for book details. This handler is **not paginated** — no cursor parameter.

| Parameter | Type     | Description     |
| --------- | -------- | --------------- |
| `book_id` | `string` | Book identifier |

Returns: [`HttpRequest`](#httprequest)

### `book_info.parse(resp)`

Parse the HTTP response into book details. Returns a single `BookInfo` table directly (not wrapped in a `Page`).

| Parameter | Type                            | Description       |
| --------- | ------------------------------- | ----------------- |
| `resp`    | [`HttpResponse`](#httpresponse) | The HTTP response |

Returns: `BookInfo`:

| Field         | Type     | Required | Description      |
| ------------- | -------- | -------- | ---------------- |
| `id`          | `string` | Yes      | Book identifier  |
| `title`       | `string` | Yes      | Book title       |
| `author`      | `string` | Yes      | Author name      |
| `cover_url`   | `string` | No       | Cover image URL  |
| `description` | `string` | No       | Book description |

### `chapters.request(book_id, cursor)`

Build the HTTP request for a book's chapter list.

| Parameter | Type           | Description       |
| --------- | -------------- | ----------------- |
| `book_id` | `string`       | Book identifier   |
| `cursor`  | `any` or `nil` | Pagination cursor |

Returns: [`HttpRequest`](#httprequest)

### `chapters.parse(resp)`

Parse the HTTP response into a chapter list.

| Parameter | Type                            | Description       |
| --------- | ------------------------------- | ----------------- |
| `resp`    | [`HttpResponse`](#httpresponse) | The HTTP response |

Returns: [`Page`](#page) of `ChapterInfo`:

| Field   | Type     | Required | Description        |
| ------- | -------- | -------- | ------------------ |
| `id`    | `string` | Yes      | Chapter identifier |
| `title` | `string` | Yes      | Chapter title      |

Chapter IDs must be unique within a single book. The runtime validates this and returns an error when a duplicate ID is encountered.

Chapters are ordered by their position in the returned list (stream order).

### `paragraphs.request(book_id, chapter_id, cursor)`

Build the HTTP request for chapter content.

| Parameter    | Type           | Description                                 |
| ------------ | -------------- | ------------------------------------------- |
| `book_id`    | `string`       | Book identifier                             |
| `chapter_id` | `string`       | Chapter identifier                          |
| `cursor`     | `any` or `nil` | Pagination cursor (for multi-page chapters) |

Returns: [`HttpRequest`](#httprequest)

### `paragraphs.parse(resp)`

Parse the HTTP response into chapter paragraphs.

| Parameter | Type                            | Description       |
| --------- | ------------------------------- | ----------------- |
| `resp`    | [`HttpResponse`](#httpresponse) | The HTTP response |

Returns: [`Page`](#page) of `Paragraph`. Each paragraph is a tagged table with a `type` discriminator and an optional `id`:

| Variant                                                         | Fields                                                                            | Description           |
| --------------------------------------------------------------- | --------------------------------------------------------------------------------- | --------------------- |
| `{ type = "title", id = string?, text = string }`               | `id`: `string` (optional), `text`: `string` (required)                            | Section/chapter title |
| `{ type = "text", id = string?, content = string }`             | `id`: `string` (optional), `content`: `string` (required)                         | Text paragraph        |
| `{ type = "image", id = string?, url = string, alt = string? }` | `id`: `string` (optional), `url`: `string` (required), `alt`: `string` (optional) | Inline image          |

**Paragraph ID:** The `id` field is optional. When omitted (`nil`), the runtime automatically assigns a sequential index (0, 1, 2, …) within the chapter. When provided, the value is used as-is. If your source provides stable, unique identifiers for paragraphs, pass them through; otherwise, simply omit `id` and let the runtime handle it.

**ID uniqueness:** Whether assigned automatically or provided by the script, IDs must be unique across all paragraphs within a single chapter (including across multiple pages when `next_cursor` is used). The runtime validates this and returns an error when a duplicate ID is encountered.

## Optional: Login Support

For sources that require authentication, add a `login` table to the return value. See [`login-handler-example.lua`](login-handler-example.lua) for a complete template.

```lua
return {
    search = { ... },
    book_info = { ... },
    chapters = { ... },
    paragraphs = { ... },
    login = {
        entry         = function() ... end,
        parse         = function(page) ... end,
        patch_request = function(context, request, auth) ... end,
        status        = { request = function() ... end, parse = function(resp) ... end },  -- optional
    },
}
```

### `login.entry()`

Returns the URL to open in a WebView for the user to log in. Takes no arguments.

Returns: `AuthEntry`:

| Field   | Type     | Required | Description                          |
| ------- | -------- | -------- | ------------------------------------ |
| `url`   | `string` | Yes      | URL to open in the WebView           |
| `title` | `string` | No       | Display title for the WebView window |

### `login.parse(page)`

Called after the WebView loads a page. Extracts authentication data from the page context.

| Parameter | Type              | Description                      |
| --------- | ----------------- | -------------------------------- |
| `page`    | `AuthPageContext` | WebView page context (see below) |

`AuthPageContext` fields:

| Field                   | Type                      | Default | Description                                        |
| ----------------------- | ------------------------- | ------- | -------------------------------------------------- |
| `page.current_url`      | `string`                  | —       | Current URL in the WebView                         |
| `page.response`         | `string`                  | `""`    | Page body as a string                              |
| `page.response_headers` | `{{string, string}, ...}` | `{}`    | Response headers as array of `{name, value}` pairs |
| `page.cookies`          | `{CookieEntry, ...}`      | `{}`    | Cookies from the WebView (see below)               |

`CookieEntry` fields:

| Field       | Type      | Required | Description                                       |
| ----------- | --------- | -------- | ------------------------------------------------- |
| `name`      | `string`  | Yes      | Cookie name                                       |
| `value`     | `string`  | Yes      | Cookie value                                      |
| `domain`    | `string`  | No       | Cookie domain                                     |
| `path`      | `string`  | No       | Cookie path                                       |
| `expires`   | `string`  | No       | Expiration timestamp                              |
| `secure`    | `boolean` | No       | Secure flag                                       |
| `http_only` | `boolean` | No       | HttpOnly flag                                     |
| `same_site` | `string`  | No       | SameSite policy: `"Lax"`, `"Strict"`, or `"None"` |

Returns: any JSON-serializable Lua table. This becomes the `auth_info`, which is persisted to disk and passed to `patch_request` on every subsequent HTTP request.

### `login.patch_request(context, request, auth)`

Called automatically on every outbound HTTP request when the user is logged in. Use it to inject authentication headers, cookies, or tokens.

| Parameter | Type                          | Description                                                 |
| --------- | ----------------------------- | ----------------------------------------------------------- |
| `context` | `RequestPatchContext`         | Describes which operation triggered the request (see below) |
| `request` | [`HttpRequest`](#httprequest) | The request table returned by the `*.request` function      |
| `auth`    | `table`                       | The `auth_info` value (whatever `login.parse` returned)     |

`RequestPatchContext` is a tagged table with an `operation` field:

```lua
-- For search:
{ operation = "search", feed_id = "..." }

-- For book_info:
{ operation = "book_info", feed_id = "...", book_id = "..." }

-- For chapters:
{ operation = "chapters", feed_id = "...", book_id = "..." }

-- For paragraphs:
{ operation = "paragraphs", feed_id = "...", book_id = "...", chapter_id = "..." }

-- For auth_status:
{ operation = "auth_status", feed_id = "..." }
```

Returns: a (possibly modified) [`HttpRequest`](#httprequest) table.

### `login.status` (optional)

An optional handler pair for checking whether the current auth session is still valid. If omitted, auth status checks are not supported for this source.

#### `login.status.request()`

Takes no arguments. Returns: [`HttpRequest`](#httprequest)

#### `login.status.parse(resp)`

| Parameter | Type                            | Description       |
| --------- | ------------------------------- | ----------------- |
| `resp`    | [`HttpResponse`](#httpresponse) | The HTTP response |

Returns: `boolean` — `true` if logged in, `false` if the session has expired.

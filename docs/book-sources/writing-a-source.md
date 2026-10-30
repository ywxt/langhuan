# Writing a book source

This guide builds a conventional HTML source. It deliberately starts with the
smallest useful design; add authentication, compute, storage, or WebView steps
only when the target site requires them.

## 1. Inspect the site first

Identify four stable paths before writing code:

1. search results;
2. one book's metadata page;
3. its chapter directory;
4. one readable chapter.

Record every hostname used by HTML, APIs, covers, and chapter images. Prefer
stable IDs already present in URLs or JSON. Do not use titles as IDs.

## 2. Add metadata

Every source starts with a header:

```js
// ==Feed==
// @id           org.example.books.demo
// @name         Demo Books
// @version      1.0.0
// @author       Example Author
// @description  Demonstration HTML source
// @base_url     https://books.example.org
// @access_domain books.example.org
// @access_domain *.cdn.example.org
// @schema_version 4
// ==/Feed==
```

Use a reverse-domain ID that you control. `@access_domain` is a security
allowlist, not documentation: every hostname a request may reach must be
declared. `*.cdn.example.org` permits subdomains but not `cdn.example.org`
itself.

The parsed header is available to the script as frozen global `meta`.

## 3. Import only the modules you need

HTML sources normally need raw-byte decoding and parsing:

```js
import { TextDecoder } from "langhuan:encoding";
import { HTML } from "langhuan:html";

const decoder = new TextDecoder("utf-8");

function bodyText(response) {
  return decoder.decode(response?.body);
}

function text(node) {
  return String(node?.text() ?? "").replace(/\s+/g, " ").trim();
}
```

Response bodies are always `Uint8Array`. Choose the page's real encoding;
`TextDecoder` also supports labels such as `gbk` and `big5`.

## 4. Implement search

The first call describes a request. The next call parses its response:

```js
function search(event) {
  if (event.state == null) {
    return {
      type: "request",
      request: {
        url: `${meta.base_url}/search`,
        method: "GET",
        params: { q: event.input.keyword },
        headers: { Accept: "text/html" },
      },
      next_state: { stage: "results" },
    };
  }

  const document = HTML.parse(bodyText(event.response));
  const items = [];
  for (const card of document.select(".book-card")) {
    const link = card.select("a.book-title").first();
    const id = link?.attr("href")?.match(/\/book\/(\d+)/)?.[1];
    if (!id) continue;
    items.push({
      id,
      title: text(link),
      author: text(card.select(".author").first()) || "Unknown",
      cover_url: card.select("img").first()?.attr("src") ?? null,
      description: text(card.select(".summary").first()) || null,
    });
  }
  return { type: "complete", items };
}
```

For paginated search, read `event.cursor` when constructing the request and
return `next_cursor` with the completed page:

```js
return { type: "complete", items, next_cursor: nextPageToken ?? null };
```

Do not keep the current page in module state. The cursor belongs to the search
operation, and a new search must start without stale pagination data.

## 5. Implement book information

`bookInfo` completes with one `value` rather than `items`:

```js
function bookInfo(event) {
  if (event.state == null) {
    return {
      type: "request",
      request: { url: `${meta.base_url}/book/${event.input.bookId}` },
      next_state: { stage: "book" },
    };
  }

  const document = HTML.parse(bodyText(event.response));
  return {
    type: "complete",
    value: {
      id: event.input.bookId,
      title: text(document.select("h1").first()),
      author: text(document.select(".author").first()) || "Unknown",
      cover_url: document.select(".cover img").first()?.attr("src") ?? null,
      description: text(document.select(".description").first()) || null,
    },
  };
}
```

## 6. Implement the chapter directory

Chapter IDs must remain stable when titles or ordering change:

```js
function chapters(event) {
  if (event.state == null) {
    return {
      type: "request",
      request: { url: `${meta.base_url}/book/${event.input.bookId}/chapters` },
      next_state: { stage: "directory" },
    };
  }

  const document = HTML.parse(bodyText(event.response));
  const items = [];
  for (const link of document.select(".chapter-list a")) {
    const id = link.attr("href")?.match(/\/chapter\/(\d+)/)?.[1];
    if (id) items.push({ id, title: text(link) });
  }
  return { type: "complete", items };
}
```

If the directory itself is paginated, return `next_cursor`. Langhuan consumes
every directory page natively and returns one finite list to the application.

## 7. Implement paragraphs

Return semantic paragraphs rather than one giant HTML string:

```js
function paragraphs(event) {
  if (event.state == null) {
    return {
      type: "request",
      request: {
        url: `${meta.base_url}/chapter/${event.input.chapterId}`,
      },
      next_state: { stage: "content" },
    };
  }

  const document = HTML.parse(bodyText(event.response));
  const items = [];
  const title = text(document.select("h1").first());
  if (title) items.push({ type: "title", text: title });

  for (const node of document.select("article p")) {
    const content = text(node);
    if (content) items.push({ type: "text", content });
  }
  return { type: "complete", items };
}
```

Paragraph IDs are optional. When omitted, the host assigns indices across the
complete chapter stream. Supply an explicit string `id` only when the website
has a stable paragraph identifier.

## 8. Export the Feed object

All four handlers are required:

```js
export default { search, bookInfo, chapters, paragraphs };
```

Module scope is private session state and is retained while this source is
loaded. Do not assign the object to `globalThis.feed`.

## Complete minimal structure

```js
import { TextDecoder } from "langhuan:encoding";
import { HTML } from "langhuan:html";

const decoder = new TextDecoder("utf-8");
const decode = (response) => decoder.decode(response?.body);

function search(event) { /* request, parse, complete items */ }
function bookInfo(event) { /* request, parse, complete value */ }
function chapters(event) { /* request, parse, complete items */ }
function paragraphs(event) { /* request, parse, complete items */ }

export default { search, bookInfo, chapters, paragraphs };
```

Use [`biquge-tw.js`](biquge-tw.js) for a complete working HTML implementation.

## Adding login

Add `login` only when native requests need a user session:

```js
const USER_AGENT = "Mozilla/5.0 ...";

const login = {
  entry() {
    return {
      url: `${meta.base_url}/login`,
      title: "Sign in",
      user_agent: USER_AGENT,
    };
  },

  parse(page) {
    const session = page.cookies.find((cookie) => cookie.name === "session");
    if (!session) return FeedError.authRequired("Login is incomplete");
    return { cookie: `session=${session.value}` };
  },

  patchRequest(operation, request, auth) {
    request.headers ??= {};
    request.headers.Cookie = auth.cookie;
    request.headers["User-Agent"] = USER_AGENT;
    return request;
  },
};

export default { search, bookInfo, chapters, paragraphs, login };
```

When present, `entry`, `parse`, and `patchRequest` are all required. An
optional `login.status(event)` reducer can verify whether stored credentials
remain valid.

## Adding another native request

Use `next_state.stage` to model an explicit state machine:

```js
function paragraphs(event) {
  if (event.state == null) {
    return requestChapterPage(event.input.chapterId);
  }
  if (event.state.stage === "page") {
    const apiUrl = discoverApi(bodyText(event.response));
    return {
      type: "request",
      request: { url: apiUrl },
      next_state: { stage: "api" },
    };
  }
  if (event.state.stage === "api") {
    return { type: "complete", items: parseApi(event.response.body) };
  }
  return FeedError.raise("invalid_state", "Unknown paragraph stage");
}
```

One operation may execute at most eight request, compute, or WebView steps.

## Errors and validation

Return expected website states:

```js
return FeedError.authRequired("Please sign in");
return FeedError.cfChallenge("Verification is required");
return FeedError.rateLimited("Try again later");
return FeedError.contentNotFound("Chapter is unavailable");
return FeedError.sourceUnavailable("Site is temporarily unavailable");
return FeedError.raise("unsupported_content", "Unknown chapter encoding");
```

Throwing is reserved for parser defects and unexpected data. Test at least:

- empty search results;
- two search pages with no duplicate IDs;
- missing optional metadata;
- a directory with many chapters;
- multi-page chapters;
- expired authentication and user cancellation;
- the site's challenge or rate-limit page.

Use the in-app [debug tools](../feed-debug-tools.md) to run each operation and
inspect redacted request traces. Consult [API Reference](api-reference.md)
when adding host modules and [Sandbox](sandbox.md) before adding compute or
WebView steps.

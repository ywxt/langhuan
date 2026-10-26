# Error Handling for JavaScript Feed Sources

Schema-3 feeds distinguish expected website states from script bugs.

## Expected failures

Return a `FeedError` value from a reducer:

```js
if (!event.auth) {
  return FeedError.authRequired("This chapter requires login");
}

if (event.response.status === 429) {
  return FeedError.rateLimited("The source is rate limiting requests");
}
```

| Helper | Code | Meaning |
| --- | --- | --- |
| `FeedError.authRequired(message)` | `auth_required` | Login is missing or expired |
| `FeedError.cfChallenge(message)` | `cf_challenge` | An anti-bot challenge blocked the page |
| `FeedError.rateLimited(message)` | `rate_limited` | Retryable throttling |
| `FeedError.contentNotFound(message)` | `content_not_found` | Book or chapter content is unavailable |
| `FeedError.sourceUnavailable(message)` | `source_unavailable` | Retryable source outage |
| `FeedError.raise(code, message)` | custom | Source-specific anticipated state |

Rust converts `{ type: "fail", code, message }` into
`ScriptError::Expected`. The bridge exposes it as `ErrorKind::ScriptExpected`,
so the UI can present an appropriate action without treating the source as
broken.

## Runtime failures

Throw an `Error` only for defects or malformed responses the source does not
know how to handle:

```js
const payload = JSON.parse(event.response.body);
if (!Array.isArray(payload.records)) {
  throw new Error("search response has no records array");
}
```

Exceptions, syntax errors, sandbox limits, out-of-memory conditions, and
deadline exhaustion become `ScriptError::JavaScript` and bridge
`ErrorKind::ScriptRuntime`.

## Native failures

HTTP execution, redirects, access-domain checks, response-size limits, and
authentication persistence are owned by Rust. Their errors never need to be
caught in JavaScript. Retryable native network failures follow the host retry
policy; permanent failures are returned directly to the UI.

## Debugging guidance

- Use expected failures for normal site states users can act on.
- Never include cookies, authorization values, tokens, or signed query
  parameters in messages.
- Let unexpected exceptions retain their stack; the developer trace view
  redacts known secrets before display.
- Persist multi-request state through `next_state`. The returned Feed object is
  retained while loaded, but closure state is not durable across application
  restarts or source reloads.

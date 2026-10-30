# Error handling for JavaScript book sources

Schema-4 sources distinguish expected website states from source defects and
native failures.

## Expected failures

Return a `FeedError` value when the website is behaving as understood but the
operation cannot complete:

```js
if (!event.auth) {
  return FeedError.authRequired("This chapter requires login");
}

if (event.response.status === 429) {
  return FeedError.rateLimited("The source is rate limiting requests");
}
```

| Helper | Code | Meaning | Retryable |
| --- | --- | --- | :---: |
| `FeedError.authRequired(message)` | `auth_required` | Login is missing or expired | No |
| `FeedError.cfChallenge(message)` | `cf_challenge` | Human or anti-bot verification blocked the page | No |
| `FeedError.rateLimited(message)` | `rate_limited` | Source throttling | Yes |
| `FeedError.contentNotFound(message)` | `content_not_found` | Book/chapter content is unavailable | No |
| `FeedError.sourceUnavailable(message)` | `source_unavailable` | Temporary source outage | Yes |
| `FeedError.raise(code, message)` | Custom | Source-specific anticipated state | No |

The host converts the returned `{ type: "fail", code, message }` into a typed
expected script error so the UI can offer a suitable action without labeling
the source as broken.

`login.parse` may also return a `FeedError` value to reject an incomplete login
without storing credentials.

## Runtime failures

Throw only for defects or response shapes the source does not understand:

```js
const payload = JSON.parse(bodyText(event.response));
if (!Array.isArray(payload.records)) {
  throw new Error("search response has no records array");
}
```

Syntax errors, exceptions, invalid handler/result shapes, duplicate IDs,
sandbox limits, out-of-memory conditions, and deadline exhaustion are runtime
errors. Their details are intended for source authors, not for control flow.

Do not catch a broad exception and convert it to “content not found”; doing so
hides parser regressions and can cache an incorrect empty chapter.

## Native failures

Rust owns URL parsing, domain checks, HTTP, redirects, retries, authentication
persistence, caching, database access, and WebView hosting. These errors do not
need to be caught in JavaScript. Retryable network failures follow the native
retry policy before reaching the UI.

## Messages and secrets

- Write messages that tell the user what action is possible.
- Never include cookies, authorization headers, tokens, signed query values,
  encryption keys, or response bodies in an error.
- Keep technical parser details in thrown runtime errors.
- Avoid dynamic secret values in request URLs where possible; trace redaction
  masks known fields but cannot infer every site-specific secret.

## Debugging

Use the [developer stage runner](feed-debug-tools.md) to inspect partial output,
typed errors, redirects, bounded body previews, and redacted request traces.
Use `next_state.stage` to make multi-request failures attributable to a clear
phase.

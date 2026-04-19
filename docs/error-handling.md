# Error Handling for Lua Feed Scripts

Langhuan provides a built-in `@langhuan/error` module that lets feed scripts raise **structured expected errors**. These errors are distinguished from unexpected runtime crashes (nil access, type errors, etc.) and allow the Flutter UI to display appropriate actions — such as a login button for auth errors or a retry button for rate limiting.

## Quick Start

```lua
local err = require("@langhuan/error")

local function ensure_logged_in(resp)
    if resp.status == 401 then
        err.auth_required("Please log in to access this content")
    end
end

local function ensure_not_blocked(resp)
    if is_cf_challenge(resp.body) then
        err.cf_challenge("Cloudflare challenge detected")
    end
end
```

## API Reference

### `require("@langhuan/error")`

Returns a table with the following functions:

### Convenience Methods

| Function | Error Code | Description |
|---|---|---|
| `err.auth_required(message)` | `auth_required` | Login is required to proceed |
| `err.cf_challenge(message)` | `cf_challenge` | Cloudflare or anti-bot challenge detected |
| `err.rate_limited(message)` | `rate_limited` | Too many requests; try again later |
| `err.content_not_found(message)` | `content_not_found` | The requested content does not exist |
| `err.source_unavailable(message)` | `source_unavailable` | The source is temporarily down |

All convenience methods take a single `message` string parameter describing the error.

### Generic Method

```lua
err.raise(code, message)
```

Raises an expected error with a custom error code. Use this for error conditions not covered by the convenience methods. The `code` parameter is a string identifier; `message` describes the error.

Custom codes are treated as `Unknown` on the Rust/Flutter side and displayed with a generic retry UI.

## How It Works

When a convenience method or `err.raise()` is called, it internally calls Lua's `error()` with a specially formatted message:

```
@langhuan_expected:<code>:<message>
```

The Rust runtime intercepts this format during `mlua::Error` → `Error` conversion and produces a `ScriptError::Expected` variant instead of `ScriptError::Lua`. This distinction flows through the bridge layer as `ErrorKind::ScriptExpected { reason }` to Flutter.

Script authors should **never** construct this prefix manually — always use the module API. The wire format is an internal implementation detail and may change without notice in future versions.

## Expected Errors vs `error()`

| | `err.auth_required("msg")` | `error("msg")` |
|---|---|---|
| Rust error type | `ScriptError::Expected` | `ScriptError::Lua` |
| Bridge error kind | `ErrorKind::ScriptExpected` | `ErrorKind::ScriptRuntime` |
| Flutter UI | Contextual action (login button, retry, etc.) | Generic "script error" message |
| Retryable | Depends on code (`rate_limited` = yes) | No |
| Localized | Yes (via `messages.yml`) | No |

Use `error()` for genuine bugs or programming errors. Use `err.*` for anticipated conditions that the user can act on.

## Flutter UI Behavior

| Error Code | Flutter Action |
|---|---|
| `auth_required` | Shows login button (navigates to WebView auth flow) |
| `cf_challenge` | Shows message suggesting browser verification |
| `rate_limited` | Shows retry button |
| `content_not_found` | Shows "content not found" message |
| `source_unavailable` | Shows retry button |
| Custom / unknown | Shows message with retry button |

## Example: Complete Feed with Error Handling

```lua
local html = require("@langhuan/html")
local err = require("@langhuan/error")

local function check_response(resp)
    if resp.body and resp.body:find("cf_chl_opt", 1, true) then
        err.cf_challenge("Anti-bot challenge detected")
    end
    if resp.status == 401 or resp.status == 403 then
        err.auth_required("Login required")
    end
    if resp.status == 429 then
        err.rate_limited("Too many requests")
    end
    if resp.status == 404 then
        err.content_not_found("Page not found")
    end
    if resp.status >= 500 then
        err.source_unavailable("Server error: " .. tostring(resp.status))
    end
end

return {
    search = {
        request = function(keyword, cursor)
            return { url = meta.base_url .. "/search?q=" .. keyword, method = "GET" }
        end,
        parse = function(resp)
            check_response(resp)
            -- ... parse search results ...
            return { items = {}, next_cursor = nil }
        end,
    },
    -- ... other handlers ...
}
```

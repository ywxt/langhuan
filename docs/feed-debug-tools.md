# Feed Developer Tools — Plan

> **Status: planning only.** This document designs a developer toolkit for
> writing and debugging Lua book sources. Nothing below is implemented yet.

## 1. Motivation

Building `docs/book-sources/qidian.lua` exposed the debugging gaps this
toolkit should close. Everything below actually happened during that work:

- **The SSR structure had to be discovered outside the app.** The m-site
  embeds all data in `<script id="vite-plugin-ssr_pageContext">`. We found
  the JSON layout with `curl` + `python3` in a terminal, not in the app —
  the app shows only the final parsed result or a generic error.
- **The auth status probe silently broke.** The keyword
  `langhuan-auth-probe` was 302'd by the m-site to a bare error page. The
  only symptom was "verification failed"; the root cause (redirect → no
  pageContext) was visible only by reading `flutter run` logs, which the
  end user cannot do.
- **Cookie capture was a black box.** Which cookies were captured, which
  were excluded, and what the probe actually returned after logging in —
  none of it was inspectable in-app.
- **Iterating on a script is slow.** Every edit requires
  `adb push` → file picker → re-import, because the feed's script lives in
  the DB and there is no in-app way to replace it.
- **WAF / challenge behaviour was invisible.** A 406 or a redirect chain
  surfaces as a plain network error; the response body that would explain
  it is discarded.

## 2. Goals

- Let a source author run **any pipeline stage** of an installed feed with
  arbitrary input and see both the raw HTTP traffic and the parsed output.
- Make the **auth flow observable**: probe URL, probe response, captured
  cookie names, status decision.
- Shorten the **edit→test loop** to seconds, without leaving the app.
- Keep all of this **invisible to normal users** and safe (no credential
  leaks, no bypass of script sandboxing).

### Non-goals

- Breakpoints / step-through Lua debugging (mlua debug hooks are a large
  detour; the stage runner gives 90% of the value).
- Running uninstalled scripts, auto-fixing scripts, or syncing scripts.
- Performance profiling.

## 3. Feature Set

### F1 — Stage Runner

A page that runs one pipeline stage of a chosen feed with custom input,
**bypassing cache and the bookshelf pipeline** (direct `LuaFeed`
invocation):

| Stage | Input | Output |
|---|---|---|
| `search` | keyword | records (title/author/cover/id) |
| `book_info` | book id | metadata + cover URL |
| `chapters` | book id | flat TOC (volume structure preserved) |
| `paragraphs` | book id + chapter id | paragraph list |
| `auth_status` | — | logged-in state + raw probe JSON |

- Runs keep a **history** (input, output, error, timestamp) so results
  before/after a script edit can be compared.
- **Chain mode**: pick a record from a `search` run to prefill
  `book_info`, pick a chapter from `chapters` to prefill `paragraphs` —
  mirroring the flow of the real reader and of the Rust smoke tests.
- Errors render with their `ErrorKind` (`ScriptExpected/AuthRequired`,
  `ScriptRuntime`, …) plus the Lua error message, so classification bugs
  (see commit `8d5d651`) are caught immediately.

### F2 — HTTP Inspector

Every debug run records its HTTP traffic at the single choke point
`langhuan/src/http.rs::execute`:

- Per request: URL, method, request headers (Cookie **masked**), status,
  elapsed ms, response size, and the final URL after redirects.
- Response **body preview** (first N KB) captured before parsing — this is
  what makes SSR extraction and WAF/challenge pages debuggable in-app.
- Blocked requests (failed `access_domains` check) are recorded too, so
  the author sees *why* nothing happened.
- Idle cost is zero: recording is active only while a debug run executes.

### F3 — Auth Debug Panel

Extends the feed's auth section (detail sheet) with a debug view:

- Stored cookie header with **names visible, values masked**, and the
  script's excluded-cookie list.
- Probe URL, probe response JSON (the `user` object for qidian), and the
  resulting status.
- Buttons: re-run probe, open the login flow (existing `feed-auth` route).

### F4 — Script Hot-Swap

Replace an installed feed's script from pasted text:

1. Paste Lua source → compile + metadata validation (same check as
   the add-feed preview).
2. Show a diff-level summary (metadata before/after).
3. Upsert into the DB under the **same feed id** — books, reading
   progress, bookmarks, and stored auth are preserved.

This turns the loop "edit → adb push → file picker → import" into
"edit → paste → validate".

### F5 — Cache & Registry Tools

- Per-feed cache inspection: entries, labels, item counts, total size.
- Clear cache for a single feed (settings only offers the global clear).

## 4. Architecture

### Rust (`hub` + `langhuan`)

- **`TraceRecorder`** in `langhuan/src/http.rs`: a global registry of
  active debug runs (`start(run_id)`, `record(run_id, entry)`,
  `finish(run_id)`), or a task-local handle threaded through
  `execute`. Entries carry a truncated body; the buffer is bounded
  (e.g. 64 entries / 256 KB per run).
- **Debug API module** (new `hub/src/api/debug.rs`, FRB-bridged):
  - `debugRunStage(feedId, stage, input) -> DebugRunResult`
    `{ output: String, error: Option<BridgeError>, trace: Vec<HttpTraceEntry> }`
  - `debugAuthState(feedId) -> DebugAuthInfo`
  - `debugUpdateFeedScript(feedId, source) -> Result<FeedMetaItem>`
  - `debugFeedCacheInfo(feedId) / debugClearFeedCache(feedId)`
- The debug functions route through the existing
  `RegistryActor`/`LoginActor` where possible, constructing a
  non-cached `LuaFeed` for stage runs.

### Flutter

- Route `/feeds/debug/:feedId` (registered in `lib/router/app_router.dart`).
- Page(s) under `lib/features/feeds/debug/`: stage runner with run
  history, trace list with expandable body previews, auth panel.
- Entry points: a "Debug" action in the feed detail sheet and a
  developer tools entry in Settings — both visible **only when
  developer mode is on**.

### Gating

- A persisted "Developer mode" toggle in Settings, off by default.
- Runtime toggle (not `kDebugMode`-only) so sources can be debugged on
  real devices running release builds.

## 5. Security & Privacy

- Cookie values and auth headers are masked in every trace and panel
  (`ywkey=<masked>`).
- Debug runs go through the same `access_domains` enforcement and cookie
  exclusion as production runs — the toolkit observes, it never widens.
- No trace or captured body leaves the device; buffers are in-memory
  only and dropped on app restart.

## 6. Phasing

| Phase | Content | Value |
|---|---|---|
| P1 | TraceRecorder + stage runner + HTTP inspector | the core loop; would have caught the probe-302 bug in seconds |
| P2 | Auth debug panel | makes login flows maintainable |
| P3 | Script hot-swap | seconds-long edit loop |
| P4 | Cache & registry tools | convenience |

## 7. Open Questions

- Body preview budget: single N-KB truncation vs first + last chunk
  (SSR data sits near the top; error pages are small anyway).
- Should the stage runner also accept an **ad-hoc script** (paste → run
  without registering a feed), or is hot-swap (F4) sufficient?
- Run history persistence: in-memory only, or persisted for comparing
  across app restarts?
- Should `debugRunStage` reuse the FRB result types of the real pipeline
  (typed records/paragraphs) or return raw JSON blobs for flexibility?

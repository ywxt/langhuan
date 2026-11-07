# Search, comments, and listening

This document describes how the application coordinates these features. For the
source contract, parameter types, and module limits, use the
[API Reference](book-sources/api-reference.md). For isolated source execution and
HTTP automation, use [Developer tools](feed-debug-tools.md).

Aggregate search, read-only comments, typed paragraph identities, and system TTS
listening are implemented. Sources must export comment handlers to expose those
actions. Listening uses the device's installed TTS engine, prefetches one chapter,
and integrates mobile background playback and system media controls.

## Aggregate search

### Execution and delivery

Sources keep their existing `search(event)` reducer. Each page completes with a
`result` array and an optional top-level `next_cursor`. Rust owns scheduling and
cancellation; Flutter owns presentation and user interaction.

1. Snapshot enabled sources at the start of a search. Disabled sources do not
   participate in that session.
2. Create one worker per source, sharing four advancement permits. Loading a
   source and advancing its stream require a permit; waiting for delivery does
   not. Workers requeue after each advance so one paginated source cannot retain
   a permit indefinitely.
3. Send attributed results through a merged queue with capacity one. Each worker
   can still retain its parsed source page and one pending result; queue capacity
   does not bound the entire search to one book in memory.
4. Cross the Rust/Flutter boundary in batches of at most 20 events. After the
   first event, coalesce for at most 40 ms before delivering a partial batch.
   The first result can wait for the network. This window is a scheduling policy,
   not an end-to-end latency guarantee.
5. Flutter displays available events and continues filling its current 20-event
   display budget in the background. This also handles a list too short to
   trigger another scroll. Keep an in-flight pull rather than starting another
   `moveNext()` after a display timeout.
6. Group results by source in arrival order. Pull more near the list end. A new
   keyword, navigation away, or cancellation ends the old session; generation
   checks keep late callbacks out of the new results.

A display batch is not one page from every source. Permits limit concurrent
advancement, not each source's share of output.

### Identity, errors, and cancellation

- Keep the first book ID within each source. Do not merge identically titled
  books across sources: editions and content may differ.
- A source failure becomes an error in its group while other workers continue.
  Application initialization failures remain overall errors.
- Deliver already received results before reporting a terminal stream error.
- Cancellation has an independent signal and can interrupt a pending bridge
  pull. Aborting the merge task drops its `JoinSet` and cancels child workers.
  Flutter still guards late results with session identity.
- HTTP timeouts, human verification, and execution limits remain independent of
  the 40 ms batching window.

There is no cross-source relevance ranking, title-based deduplication, or
persistent search-result cache.

## Read-only website comments

### Exports and support detection

```js
export default {
  search,
  bookInfo,
  chapters,
  paragraphs,
  comments: {
    chapter: chapterComments,
    paragraph: paragraphComments,
  },
};
```

Either handler, or `comments` itself, may be absent or `null`. Other malformed
exports fail loading. The host inspects these exports without executing them;
there is no separate capability declaration. Returning an empty comment page
means supported with no results, rather than unsupported.

Both handlers read existing comments and replies. They expose no posting,
liking, voting, purchasing, subscription, or deletion operations. Login and
human verification use the existing independent authentication flow. There is
no sort argument; each source uses the website's default order. Invalid and
disabled sources do not execute comment handlers.

### Paragraph identity

A paragraph carries its original identity separately from transformations:

```rust
enum OriginalParagraphId {
    Source(String),
    Generated(u64),
}

struct ParagraphId {
    original: OriginalParagraphId,
    path: Vec<u32>,
}
```

The source returns an ordinary paragraph such as
`{ type: "text", id: "839", content: "Example." }`. The host wraps an explicit
ID as `Source`; omitted IDs become `Generated` identities in pre-transformation
order. Numeric source strings remain source identities, not host indices.

```text
Original       { original: Source("839"), path: [] }
First split    { original: Source("839"), path: [0] }
               { original: Source("839"), path: [1] }
Split again    { original: Source("839"), path: [1, 0] }
               { original: Source("839"), path: [1, 1] }
```

One-to-one conversions retain the full identity. A split appends an output index
to each descendant's path. Dropping one paragraph does not renumber another
original identity. The current per-original transformation chain does not merge
different originals or synthesize paragraphs with no input identity.

Display keys, bookmarks, caches, and progress use the full typed identity,
scoped by source, book, and chapter. Paragraph comments use only the original
`Source` value. A generated ID does not enable paragraph comments, even if the
source exports `comments.paragraph`. There is no separate `comment_ref`.

Stored IDs use tagged encoding. Invalid untagged values are not guessed from
numeric strings. Restoration first matches the full identity, then the first
descendant of the same original, and finally the chapter start. Ordinary reading
also validates character offsets; listening stores paragraph positions only.

### Query and page shape

Both exports receive the normal reducer event. `parentId` selects a reply list;
`event.cursor` selects a page within that list.

```js
// Chapter comments; omit paragraphId.
{ bookId: "123", chapterId: "456", parentId: null }

// Paragraph comments.
{ bookId: "123", chapterId: "456", paragraphId: "839", parentId: null }

// Existing replies to paragraph comment c7; use the same export.
{ bookId: "123", chapterId: "456", paragraphId: "839", parentId: "c7" }
```

The first page has a `null` cursor and `undefined` state. State belongs to one
page's request/compute sequence; it is not a pagination token. Multiple steps may
produce one completed website page:

```js
return {
  type: "complete",
  result: {
    items: [{
      id: "c7",
      author: { name: "Reader" },
      text: "An interesting paragraph.",
      replies: { total_count: 3 },
    }],
    total_count: null,
  },
  next_cursor: { page: 2 },
};
```

An absent or `null` cursor ends the list; an empty page alone does not. Replies
have independent cursors. `replies: null` hides the replies action;
`replies: { total_count: null }` exposes it with an unknown count. The reference defines the input types
[`ChapterCommentsInput`](book-sources/api-reference.md#chapter-comments-input) and
[`ParagraphCommentsInput`](book-sources/api-reference.md#paragraph-comments-input),
plus [`Comment`](book-sources/api-reference.md#comment) and
[`CommentResult`](book-sources/api-reference.md#comment-result), with field-level
behaviour and limits.

### Host and UI

The host applies authentication, domain checks, retries, and resource limits to
comment requests. Comment operations bypass helper-response caching and return
one page at a time. The UI preserves loaded comments when a later page fails,
retries the same cursor, deduplicates overlaps, and rejects cursor loops. Refresh
replaces the session; closing the panel cancels pending work.

Phones use a bottom sheet and wide layouts use a side dialog. Paragraph actions
appear only when the visible paragraph has an original source ID. Developer tools
and the Agent API use exactly `comments.chapter` and `comments.paragraph`, with
explicit input and cursor values.

Chapter comments additionally render inline at the end of their chapter in both
reader modes: a sliver below the chapter's last paragraph in vertical mode, one
page after the chapter's last text page in horizontal mode. The inline section
shows its first loaded pages with a load-more affordance; controllers are cached
per chapter and pruned with the reading window, so revisiting a chapter keeps
its loaded pages. The reader's single comment switch controls paragraph badges
and the inline chapter-end sections together; there is no separate
chapter-comment action, and toggling it never re-pages text.

## Listening with the device TTS engine

### Platform adapters

Android, iOS, macOS, and Windows use `flutter_tts` to call the installed system
engine. Voice availability, voice-data downloads, and any network use belong to
that engine. The application does not filter voices by network-related flags or
connect to a separate synthesis service.

Linux runs an owned `espeak-ng` process. Stopping playback terminates only that
process. Install eSpeak NG in the runtime environment; for a Nix development
session, use `nix shell nixpkgs#espeak-ng -c flutter run -d linux`. An unavailable
engine or empty voice list produces an error rather than silent success.

### Controller and playback

`SpeechEngine` exposes `voices()`, `speak(text, voice, rate)`, and `stop()`.
`ListeningController` coordinates chapter loading, speech completion, navigation,
voice/rate changes, sleep timers, and persistence. Its states are `idle`,
`loading`, `playing`, `paused`, `completed`, and `error`. A generation counter
isolates callbacks from superseded playback sessions.

The controller speaks titles and text, skipping images and empty paragraphs.
It uses transformed text content directly. Layout Transformers such as first-line
indentation set paragraph metadata rather than inserting whitespace; listening
therefore needs no indentation-specific text cleanup. Source whitespace and
explicit Regex replacements retain their normal text semantics.
Utterances contain at most 240 UTF-16 code units, prefer punctuation boundaries,
and never split a surrogate pair. These chunks are engine inputs, not saved
positions. The next chapter is prefetched while the current chapter plays; no
audio for the entire book is pre-generated. Failed prefetches are retried when
needed. Changing effective Transformer rules discards both retained and
prefetched transformed paragraphs; paused sessions reload on resume and active
sessions restart the current paragraph with the new rules. Chapter failures stop playback and expose an error. Finishing the
last chapter enters `completed`.

### Paragraph-level progress

Listening and reading share one reading-progress record per source and book.
There is no separate listening-position model, API, or database table. Starting
from the reader uses its currently visible chapter and paragraph. Starting a new
session outside the reader loads the same persisted reading progress.

Playback records the target chapter before loading its first paragraph, so a
failed chapter remains the retry position. Entering each spoken paragraph
updates the same reading progress, with the character offset set to zero. The
reader follows and highlights that paragraph,
turning pages or scrolling as needed. Individual speech chunks do not write
progress. Pause and stop do not write an older speech position over newer manual
reading progress.

Pause/resume and voice/rate changes restart the retained spoken paragraph,
independently of manual browsing during the same session. A new session loads
persisted reading progress unless the reader supplies an explicit position.
Ordinary reading retains its character offsets; speech writes paragraph boundaries.

Playback and the viewport have independent positions during a live session:

- By default, the reader follows and highlights narration, moving only when the
  spoken paragraph is outside the current viewport.
- Swiping, scrolling, using the mouse wheel, selecting text, or navigating through
  the catalogue or bookmarks detaches the viewport without pausing speech.
- **Return to narration** restores following and reveals the spoken paragraph.
- **Listen from here**, available from a selected text paragraph or the listening
  panel after browsing, explicitly starts narration at that position.

While same-book speech is playing or loading, only its controller persists
progress. Viewport changes still update the reader's in-memory position, so its
chapter indicator, catalogue selection and navigation reflect what is on screen.
Pausing or stopping allows ordinary reading to persist progress again. A paused
session retains its own paragraph for resume; this position is runtime state,
not a second database record. Closing the application discards that session.
Queued viewport saves and deferred follow jumps are cancelled when necessary to
prevent either position from unexpectedly overwriting or moving the other.

Voice and rate selection are persisted in SharedPreferences. Concurrent setting
changes preserve playback intent, while an explicit pause or stop cancels any
pending automatic restart.

### Background playback and system controls

Hiding the application or locking the screen does not pause speech.
`ListeningBackgroundPlayback` prepares an `audio_service` handler and a speech
`audio_session` before the first utterance. Android declares a media-playback
foreground service and wake-lock permission; iOS enables the audio background
mode. Windows and Linux retain their desktop playback adapters without a mobile
service. Mobile notification and lock-screen commands delegate to the same
`ListeningController`, including pause/resume, stop, paragraph navigation, and
rate changes. There is no separate background player or progress record.

Audio interruptions and disconnected headphones pause playback without
silently restarting it. A paused Android session retains its foreground service
so it can resume from the lock screen; stop, failure, or completion publishes an
idle OS state to release the service. The application UI retains its completed
or error state. Removing the Android task stops playback. Force-stop and process
death do not automatically restart speech.

Sleep timers continue in the background. Deadline checks also run before each
chapter. Resume restarts the current paragraph and uses the shared reading
progress. The system session owns audio focus across utterances rather than
requesting and abandoning focus for every chunk.

## Validation

Unit tests cover scheduling, cancellation, cursor handling, typed IDs, playback
state, chunk boundaries, and generation isolation. Integration tests use the real
Rust bridge, local HTTP fixture sources, and an isolated SQLite directory.
Listening integration additionally exercises playback controls, paragraph-level
pause/restoration, cross-chapter completion, and failure reporting with a
controlled speech adapter. A separate device check uses the real installed TTS
engine and requires an available voice; it must not silently skip synthesis.

Run the tests with:

```sh
flutter test
flutter test integration_test/aggregated_search_test.dart -d linux
flutter test integration_test/reader_comments_listening_test.dart -d linux
flutter test integration_test/listening_test.dart -d linux
flutter test integration_test/listening_reader_test.dart -d linux
flutter test integration_test/system_tts_test.dart -d DEVICE_ID --no-uninstall
python3 dev/test_background_listening.py --device DEVICE_ID
```

Use an unlocked device for the system-engine test. It plays a short utterance.
Run device tests with `--no-uninstall` to preserve installed application data;
fixtures use their own data directory.

The background listening device test uses an offline book fixture and the real
installed TTS engine. The host script waits for `BACKGROUND_TTS_READY`, sends HOME, switches the
screen off during the 35-second window, and checks the foreground service. The
test also requires an actual background lifecycle event. It verifies paragraph progress
continues, then exercises the registered media handler's pause/resume/stop
commands. It requires a working system voice and does not skip synthesis.

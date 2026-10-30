# Book-source developer tools

Langhuan includes an isolated stage runner for developing schema-4 sources on
the same device that runs the app. It executes editor contents directly; a
work-in-progress source does not need to be installed first.

## Opening the tools

Developer mode is hidden by default. Unlock it from Settings, then open the
developer-tools page. The page keeps the current editor text locally so an
accidental navigation does not discard a long script.

You can paste a source or load the current script of an installed source into
the editor. Loading is read-only: debug runs never replace the installed
script, source registry, bookshelf, or caches.

## Stage runner

Choose one stage and enter its input:

| Stage | Input | Output |
| --- | --- | --- |
| Search | Keyword | Every search result page |
| Book info | Book ID | Parsed book metadata |
| Chapters | Book ID | Complete chapter directory |
| Paragraphs | Book ID and chapter ID | Parsed paragraph list |
| Auth status | None | Logged-in, logged-out, or expired status |

Each run compiles a fresh source object in the production sandbox and uses the
production request, reducer, domain-policy, authentication-patching, and parser
paths. It does not use normal response or bookshelf caches.

If an installed source with the same ID has stored authentication, the runner
hydrates that value read-only. The result shows whether authentication is not
supported, missing, or applied.

## Results and partial output

A run reports:

- compiled source identity and version;
- typed stage output;
- terminal error and error category;
- total duration;
- authentication usage;
- native HTTP trace.

Search, chapter, and paragraph stages retain items parsed before a later page
fails. Partial output and the terminal error are shown together, which makes a
bad cursor or one malformed page visible.

The page keeps an in-memory run history so results can be compared while
editing. Restarting the app clears run results; editor text is persisted.

## HTTP inspector

Every native request made during the run appears in execution order with:

- method and requested URL;
- final URL after redirects;
- response status, size, and elapsed time;
- request headers with sensitive values masked;
- a bounded response-body preview;
- native error details;
- requests rejected by the domain allowlist.

The recorder is scoped to the debug run. Traces remain in memory, have bounded
entry/body budgets, and are dropped on restart. The result reports how many
entries were omitted after the limit.

## Safety properties

The developer tools observe the production path; they do not widen it:

- the source still has no HTTP or system API;
- `@access_domain` enforcement remains active;
- stored auth is read-only;
- cookie, authorization, and known secret values are masked;
- editor contents are not installed or written to the source database;
- trace data does not leave the device.

Avoid putting credentials in source code or error messages: source text and
script-provided messages cannot be reliably redacted.

## Recommended workflow

1. Run search with a keyword that has known results and an empty-result query.
2. Copy one result ID into book info.
3. Run chapters and inspect the first, middle, and last IDs.
4. Run paragraphs for free, protected, and late chapters as applicable.
5. Run auth status before and after login.
6. Check every trace host against the metadata allowlist.
7. Test a second search page and verify IDs do not repeat.
8. Only then import the source through the normal safety preview.

The stage runner is not a JavaScript debugger: it has no breakpoints or object
inspector. Use explicit stage state, small parsing helpers, typed expected
errors, and the HTTP trace to locate failures.

# Documentation

Langhuan's documentation is written in English. Start with the product overview
in the [project README](../README.md), then choose a guide below.

| Guide | Purpose |
| --- | --- |
| [Book sources](book-sources/README.md) | Source architecture, examples, sandbox policy, and the API Reference. |
| [Developer tools](feed-debug-tools.md) | Editor workflows, operation and step debugging, and the Agent HTTP API. |
| [Error handling](error-handling.md) | Expected website failures, runtime defects, native errors, and safe messages. |
| [Search, comments, and listening](search-comments-listening.md) | Application coordination, paragraph identity, system TTS, and validation. |
| [UI design guide](ui-design-spec.md) | Visual principles, theme tokens, component layout, and interaction rules. |

## Conventions

Use sentence-case headings, present tense for implemented behaviour, and a
separate remaining-work section for proposals. Keep examples executable where
possible and label illustrative endpoints. API documentation specifies each
parameter's type, default, behaviour, failure conditions, and resource limits.

Use **book source** for the script/package, **host** for native execution and
policy enforcement, **reducer** for an exported operation handler, and **page**
for one completed source result with its cursor. A **batch** is a bounded bridge
or display delivery, which can contain results from several source pages.
Use **listening** for the product feature and **system TTS engine** for speech
synthesis. API identifiers retain their exact spelling and casing.

The current source contract is schema 6. The
[API Reference](book-sources/api-reference.md) is authoritative for the public
source surface; architecture guides describe how those interfaces are used.

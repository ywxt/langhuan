# Langhuan (琅嬛)

Langhuan is a cross-platform reader that brings books from different websites
into one quiet, consistent reading experience. Add the sources you trust,
search across them, keep a personal bookshelf, and continue reading without
being tied to one catalogue or one website.

> [中文版](README.zh.md)

## What you can do

- **Read from your own sources** — Import JavaScript book sources without
  waiting for an app release. Sources can cover ordinary HTML sites, logged-in
  accounts, and multi-request chapter APIs.
- **Search in one place** — Search one source or aggregate results from all
  enabled sources while keeping failures isolated to the source that failed.
- **Keep a real bookshelf** — Open a shelved book directly, see reading and
  chapter progress, check for updates, bookmark passages, and manage books with
  familiar swipe actions.
- **Choose how reading feels** — Switch between horizontal pages and seamless
  vertical reading, change fonts and spacing, and create custom reader themes.
- **Read Chinese your way** — Convert content to Traditional Chinese, Taiwan
  usage, or Hong Kong variants while reading.
- **Keep useful data local** — Cache books and chapters for fast reopening,
  preserve shelved content during maintenance, and export or import sources.
- **Sign in when a source needs it** — Complete login or human verification in
  an embedded browser; the source then reuses the captured session for native
  requests.

## Designed around source safety

A book source does not receive an HTTP client, filesystem access, environment
variables, or process access. It describes what it needs; the Rust host checks
the destination against the source's declared domains and performs the request.
Scripts run in a bounded native QuickJS sandbox, and powerful helpers such as
HTML parsing, encoding, and cryptography are exposed as explicit modules.

Book sources are still third-party code. Review their identity, declared
domains, and publisher before importing them. Only sign in through a source you
trust.

## Platforms

The application targets Android, Linux, macOS, and Windows. Platform packages
are produced by tagged releases; availability may vary while the project is
under active development.

## Book sources

Start with the [book-source documentation](docs/book-sources/README.md):

- [architecture and execution model](docs/book-sources/architecture.md);
- [step-by-step authoring guide](docs/book-sources/writing-a-source.md);
- [sandbox capabilities and limits](docs/book-sources/sandbox.md);
- [complete host-module API reference](docs/book-sources/api-reference.md).

The repository includes sources for a conventional HTML site and more involved
authenticated or encrypted sites under [`docs/book-sources`](docs/book-sources).

## Development

The recommended environment is the repository's Nix flake on x86_64 Linux. It
provides Flutter, Rust, Android SDK/NDK, the emulator, and the matching
`flutter_rust_bridge` generator.

```bash
nix develop
flutter_rust_bridge_codegen generate
flutter run
```

Without Nix, install Flutter, Rust, the required platform toolchain, and
`flutter_rust_bridge_codegen` 2.13.0. When changing functions in
`native/hub/src/api/`, regenerate the bridge before building. Generated files
under `lib/src/rust/` and `native/hub/src/frb_generated.rs` must not be edited
manually.

Useful checks:

```bash
flutter analyze
flutter test
cargo test --workspace
```

## Project status

Langhuan is under active development. Book-source contracts may evolve before
the first stable release, and checked-in sources are examples rather than a
promise that a third-party website will remain unchanged.

## License

Langhuan is licensed under the [MIT License](LICENSE). Individual example book
sources can carry their own license notice.

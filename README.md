# Langhuan (琅嬛)

A cross-platform web novel reader with **user-defined book sources**. Write a sandboxed JavaScript reducer, point it at any website, and start reading — no app update required.

Built with Flutter (UI), Rust (backend), and an isolated native QuickJS runtime (scripting).

> [中文版](README.zh.md)

## Features

- **Sandboxed JavaScript Book Sources** — Define how to search and parse novel content with schema-3 reducers. Rust owns HTTP and authentication; scripts run in a capability-free native QuickJS runtime.
- **Cache Management** — Local chapter caching with automatic stale data cleanup; bookshelf items are preserved.
- **Localization** — English and Chinese.

## Tech Stack

| Layer     | Technology                    |
| --------- | ----------------------------- |
| UI        | Flutter + Riverpod + GoRouter |
| Bridge    | flutter_rust_bridge v2        |
| Backend   | Rust + Tokio (Actor model)    |
| Scripting | Native QuickJS sandbox          |
| HTTP      | reqwest + rustls              |

## Project Structure

```
lib/                        # Flutter frontend
├── features/               # Feature modules (bookshelf, feeds, settings)
├── router/                 # GoRouter configuration
├── shared/                 # Shared services, theme, widgets
└── l10n/                   # Localization resources (ARB)

native/langhuan/            # Core Rust library (pure domain logic)
├── src/
│   ├── script/             # Native QuickJS sandbox and feed runtime
│   ├── cache/              # Cache storage
│   ├── bookshelf/          # Bookshelf persistence
│   ├── progress/           # Reading progress
│   ├── auth/               # Login & authentication
│   └── feed/               # Feed loading & registry

native/hub/                 # FRB bridge layer + Actor system
├── src/
│   ├── api/                # FRB API (public functions callable from Dart)
│   └── actors/             # Message-passing actors
```

## Building

### With Nix (recommended)

The development environment is fully declarative: a Nix flake provides Flutter (stable), a stable Rust toolchain with the Android cross-targets, the binding generator, the Android SDK/NDK with licenses already accepted, the emulator, and one Pixel 7 AVD (Android 16) provisioned into the project-local `.avd/` directory. The SDK carries every platform the app and its plugins compile against (API 35 and 36) plus only the one system image its AVD boots (API 36), so nothing is ever downloaded at build time.

Requirements: Nix (with flakes) and [direnv](https://direnv.net/) on an x86_64-linux host.

```bash
direnv allow                            # or: nix develop
flutter doctor                          # everything should be green
flutter_rust_bridge_codegen generate    # required before the first build
emulator -avd Pixel_7_API_36            # optional: launch an emulator
flutter run                             # run on a device or emulator
flutter build apk --release             # or --debug; APK in build/app/outputs/flutter-apk/
```

`flutter run -d linux` works as well.

### Without Nix

Install the toolchain manually:

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (stable, Dart ≥ 3.11.3)
- [Rust toolchain](https://www.rust-lang.org/tools/install) with the Android cross-targets:

  ```bash
  rustup target add aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android
  ```

- The Android SDK with accepted licenses and the NDK version Flutter pins (`flutter doctor` points out anything missing)

```bash
cargo install flutter_rust_bridge_codegen --version 2.13.0   # first time only
flutter doctor
flutter_rust_bridge_codegen generate    # required before the first build
flutter run
```

### Bindings

When you later modify the Rust API surface (functions in `native/hub/src/api/`), re-run `flutter_rust_bridge_codegen generate` to update the bindings. The generated Dart code lives in `lib/src/rust/` and the generated Rust code in `native/hub/src/frb_generated.rs` — do not edit these files manually.

> The `flutter_rust_bridge` version must stay aligned across the Dart runtime (`pubspec.lock`), the Rust crate (`native/hub/Cargo.toml`), and the codegen. In the Nix environment, run `flutter pub upgrade flutter_rust_bridge` after `nix flake update` — the next `generate` auto-upgrades the Rust crate. With a manual setup, keep the `cargo install`ed codegen at the same version.

## Book Source Scripts

Book sources are schema-3 JavaScript reducers that return request descriptors while native Rust owns all HTTP. See the [book source documentation](docs/book-sources/README.md) for the full scripting guide, sandbox contract, and examples.

## License

This project is licensed under the [MIT License](LICENSE).

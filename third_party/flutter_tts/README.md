# flutter_tts local patch

Source: [dlutton/flutter_tts](https://github.com/dlutton/flutter_tts), pub.dev
release [4.2.5](https://pub.dev/packages/flutter_tts/versions/4.2.5).
Upstream archive SHA-256:
`ce5eb209b40e95f2f4a1397116c87ab2fcdff32257d04ed7a764e75894c03775`.
The upstream MIT license and changelog are retained. The example application,
generated documentation, and standalone Gradle wrapper are omitted.

## Local changes

- Migrate the Android build to AGP-provided Kotlin: remove the external Kotlin
  Gradle plugin, its buildscript dependency, and the explicit Kotlin standard
  library dependency.
- Use `kotlin.compilerOptions` and Java/Kotlin target 17.
- Resolve Android build plugins and repositories from the application.
- Use the current Android namespace and lint DSL directly.
- Declare Flutter 3.44 / Dart 3.12 as the plugin's minimum SDK versions, following
  the [official migration guide](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-plugin-authors).
- Identify this patch as `4.2.5+langhuan.1`; prevent accidental publication.

Runtime sources and platform registrations are copied from the upstream
release without changes. The application uses Flutter 3.47.4 with
`android.builtInKotlin=true`. `android.newDsl=false` remains necessary for the
current Flutter/plugin toolchain; it is independent of Kotlin compilation.
The application's settings buildscript pins the Kotlin compiler/API dependency
to 2.4.0 because AGP 9.2's default 2.2.10 is below Flutter 3.47's required
minimum. This does not apply the external Kotlin Android plugin. Application
analysis excludes the unchanged third-party runtime sources.

## Updating

When an upstream release supports built-in Kotlin, replace the path dependency
in the application's `pubspec.yaml` with that release and remove this directory.
Before doing so, inspect upstream runtime changes, build Android, and run
`integration_test/system_tts_test.dart` on an unlocked device with an installed
system voice. Do not patch the shared Pub cache or suppress migration warnings.

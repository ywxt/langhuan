# The nixpkgs flutter wrapper, patched for the two places where Flutter's
# gradle integration collides with the read-only nix store.
#
# nixpkgs' flutter wrapper ships a Groovy settings shim for the
# flutter_tools/gradle includeBuild that redirects the plugin's
# project and build directories into ~/.cache (the SDK itself is
# a read-only store path). The shim loads the sibling Kotlin
# settings script with `apply from:`, which leaves the build's
# settings state unattached and deterministically crashes
# Gradle >= 9.1's configuration-cache promo handler ("The
# settings are not yet available for build"). Override the
# wrapper to install a shim that declares the repositories
# directly; see flutter-tools-settings-gradle9.gradle.
# The wrapper is a symlinkJoin: its real build script lives in
# buildCommand (postBuild hooks never run), so append there.
# A second patch replaces native_plugin_loader.gradle.kts, the
# interpreted script the compiled FlutterAppPluginLoaderPlugin
# reflectively calls to enumerate Android plugins: Gradle >= 9
# requires every project directory to be writable, so plugins
# that live inside the read-only SDK (integration_test, pulled
# in by its dev dependency) must be mirrored into ~/.cache;
# see flutter-native-plugin-loader-nix.gradle.kts.
{ pkgs }:
{
  flutterGradle9 = pkgs.flutter.overrideAttrs (old: {
    buildCommand = old.buildCommand + ''
      rm "$out/packages/flutter_tools/gradle/settings.gradle"
      cp "${./flutter-tools-settings-gradle9.gradle}" \
        "$out/packages/flutter_tools/gradle/settings.gradle"
      rm "$out/packages/flutter_tools/gradle/src/main/scripts/native_plugin_loader.gradle.kts"
      cp "${./flutter-native-plugin-loader-nix.gradle.kts}" \
        "$out/packages/flutter_tools/gradle/src/main/scripts/native_plugin_loader.gradle.kts"
    '';
  });
}

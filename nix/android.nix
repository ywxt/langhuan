# Android SDK composition for Langhuan.
#
# The SDK is composed from two androidenv builds merged into one root: a
# build side carrying every platform AGP must find — the compileSdk levels
# the app and the Android plugins declare (35, 36) — plus the NDK pinned by
# Flutter 3.47 for the Rust cross builds, and an emulator side carrying
# only the API 36 system image the AVD boots plus the emulator itself.
# androidenv cross-products system images with platforms, so a single
# composition would pull a > 4 GB image for every build platform; the
# split keeps the image list pinned to what the AVD actually boots. A
# mutable SDK would auto-install the extra platforms on demand; the
# read-only nix store cannot, so they are declared here. The AVDs
# themselves are store artifacts too: avdmanager runs at build time
# against the emulator-side SDK and the shells materialize the read-only
# result into a writable AVD home, because the emulator must create lock
# files, userdata and snapshots inside each .avd directory.
{ pkgs, lib }:
let
  jdk = pkgs.jdk; # AGP 8/9 requires JDK 17+

  # ── Project configuration ─────────────────────────────────────
  # Every platform AGP must find to compile the app and the
  # Android plugins: the app's compileSdk (36) plus the level the
  # jni plugins declare themselves (35; they arrive transitively
  # via path_provider_android). shared_preferences_android follows
  # flutter.compileSdkVersion.
  # Nothing declares 34 any more — flutter_inappwebview_android
  # switched to flutter.compileSdkVersion in 6.2.0 and the last
  # fixed-34 plugin (fluttertoast) was replaced with a pure
  # Flutter toast — so that platform and its system image are not
  # carried. A mutable SDK would auto-install missing platforms
  # on demand, but the nix store is read-only, so they are listed
  # explicitly.
  platformVersions = [
    "35" # compileSdk declared by jni / jni_flutter
    "36" # flutter.compileSdkVersion / targetSdkVersion (Android 16)
  ];

  # Build-tools version AGP 9.x requests.
  buildToolsVersions = [ "36.0.0" ];

  # flutter_rust_bridge cross-compiles Rust into the APKs;
  # android/app/build.gradle uses `ndkVersion = flutter.ndkVersion`,
  # which Flutter 3.47 pins to this exact version. Both the version
  # list and includeNDK are required.
  ndkVersions = [ "28.2.13676358" ];

  # License hashes written into both SDK compositions below so
  # `flutter doctor --android-licenses` passes without prompts
  # (the store paths are read-only, so nothing can be accepted
  # later). Only android-sdk-license is written by default, but
  # sdkmanager — which flutter doctor runs to validate licenses —
  # requires the hashes of every license referenced by the
  # repository, otherwise it reports "Some Android licenses not
  # accepted". These names cover all licenses known to
  # androidenv's repo.json and must stay identical across both
  # compositions.
  extraLicenses = [
    "android-sdk-arm-dbt-license"
    "android-sdk-preview-license"
    "android-googletv-license"
    "android-googlexr-license"
    "google-gdk-license"
    "intel-android-extra-license"
    "intel-android-sysimage-license"
    "microxr-sysimage-license"
    "mips-android-sysimage-license"
  ];

  # AVDs built by nix (see androidAvds) and materialized into the
  # AVD home on first entry of the default shell.
  # `avdmanager list device` prints all available device ids.
  avds = [
    {
      name = "Pixel_7_API_36";
      device = "pixel_7";
      package = "system-images;android-36;google_apis;x86_64";
    }
  ];
  # ─────────────────────────────────────────────────────────────────

  # Build-side SDK: the platforms AGP compiles against,
  # build-tools, the NDK and pre-accepted licenses — no emulator
  # and, crucially, no system images (see androidSdkEmulator).
  androidSdkBuild =
    (pkgs.androidenv.composeAndroidPackages {
      inherit
        platformVersions
        buildToolsVersions
        ndkVersions
        extraLicenses
        ;
      includeEmulator = false;
      includeSystemImages = false;
      includeNDK = true;
      # Google's cmake package stays out of the closure entirely;
      # the jni plugin's cmake/3.22.1 directory is provided by
      # the merges below.
      includeCmake = false;
    }).androidsdk;

  # Emulator-side SDK: androidenv only builds system images for
  # platforms the composition also installs, so this carries the
  # API 36 platform (already present in the build SDK) purely to
  # pull the one google_apis/x86_64 image the AVD boots, plus the
  # emulator itself. Everything else is left out.
  androidSdkEmulator =
    (pkgs.androidenv.composeAndroidPackages {
      platformVersions = [ "36" ];
      buildToolsVersions = [ ];
      systemImageTypes = [ "google_apis" ];
      abiVersions = [ "x86_64" ];
      inherit extraLicenses;
      includeEmulator = true;
      includeSystemImages = true;
      includeNDK = false;
      includeCmake = false;
    }).androidsdk;

  # AGP's default externalNativeBuild CMake version is 3.22.1
  # (the jni plugin does not pin another one), so the SDK must
  # provide exactly that version. The prebuilt ninja Google ships
  # inside its SDK cmake packages segfaults on this host —
  # strace shows SEGV_ACCERR in the binary's own text segment
  # during early startup, on glibc 2.44 (both the 3.22.1 and the
  # 4.1.2 packages are affected; the cmake binary itself is fine),
  # which is why includeCmake = false keeps the package out
  # entirely. Provide the cmake/3.22.1 directory from nixpkgs'
  # cmake and ninja instead. AGP identifies the version by
  # directory name only, and jni's CMakeLists requires
  # CMake >= 3.10, which nixpkgs' current cmake satisfies.
  cmake3221 = pkgs.runCommand "cmake-3.22.1-sdk-dir" { } ''
    mkdir -p $out/bin
    ln -s ${pkgs.cmake}/bin/cmake $out/bin/cmake
    ln -s ${pkgs.cmake}/bin/cpack $out/bin/cpack
    ln -s ${pkgs.cmake}/bin/ctest $out/bin/ctest
    ln -s ${pkgs.ninja}/bin/ninja $out/bin/ninja
  '';

  # One SDK root for the default shell's ANDROID_HOME and PATH: the
  # build SDK wholesale, plus the emulator and system images from the
  # emulator SDK, plus the cmake/3.22.1 directory. The merge is
  # explicit rather than a symlinkJoin because both compositions
  # also link the same shared entries (cmdline-tools,
  # platform-tools, licenses) — linking one side wholesale and
  # only filling the gaps from the other keeps the result
  # deterministic regardless of collision handling.
  androidSdk = pkgs.runCommand "androidsdk" { } ''
    mkdir -p $out/libexec/android-sdk $out/bin
    for entry in ${androidSdkBuild}/libexec/android-sdk/*; do
      ln -s "$entry" "$out/libexec/android-sdk/$(basename "$entry")"
    done
    for tool in ${androidSdkBuild}/bin/*; do
      ln -s "$tool" "$out/bin/$(basename "$tool")"
    done
    ln -s ${androidSdkEmulator}/libexec/android-sdk/emulator \
      "$out/libexec/android-sdk/emulator"
    ln -s ${androidSdkEmulator}/libexec/android-sdk/system-images \
      "$out/libexec/android-sdk/system-images"
    for tool in ${androidSdkEmulator}/bin/*; do
      [ -e "$out/bin/$(basename "$tool")" ] ||
        ln -s "$tool" "$out/bin/$(basename "$tool")"
    done
    mkdir -p "$out/libexec/android-sdk/cmake"
    ln -s ${cmake3221} "$out/libexec/android-sdk/cmake/3.22.1"
  '';

  # The AVDs above, built at build time rather than created
  # imperatively at shell entry. The avdmanager on PATH is the
  # merged SDK's, whose wrapper hard-codes --sdk_root at the
  # build-side composition — a root without system images, so
  # package validation can never succeed there ("Valid system
  # image paths are: null"); the shellHook used to call it and
  # always failed. The emulator-side SDK's own wrapper points at
  # the composition that carries the image, so creation runs
  # against that side instead. An AVD is only a config.ini plus a
  # 3-line pointer .ini (the emulator generates userdata inside
  # the materialized copy on first boot); image.sysdir.1 stays a
  # path relative to the SDK root, which both compositions
  # resolve. The "Could not load devices from .../devices.xml"
  # messages avdmanager prints are noise: this image ships no
  # devices.xml, so avdmanager falls back to the definitions
  # bundled with cmdline-tools and -d pixel_7 still applies.
  androidAvds = pkgs.runCommand "android-avds"
    {
      # The gradle-style launcher inside cmdline-tools looks for
      # java via `which`, which the build sandbox does not put on
      # PATH; a set JAVA_HOME makes it use $JAVA_HOME/bin/java
      # directly and skip that check.
      JAVA_HOME = jdk.home;
    }
    ''
      export HOME="$PWD/.home" # java needs a writable $HOME
      mkdir -p "$HOME" "$out"
      export ANDROID_AVD_HOME="$out"
      ${lib.concatMapStrings (avd: ''
        echo no | ${androidSdkEmulator}/bin/avdmanager create avd \
          -n "${avd.name}" -k "${avd.package}" -d "${avd.device}"
      '') avds}
    '';
in
{
  inherit
    androidSdk
    androidAvds
    avds
    ;
}

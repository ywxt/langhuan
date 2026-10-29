# The dev shells, composed from the sibling modules: android.nix builds
# the SDK roots, rust.nix the Rust toolchain and flutter.nix the patched
# flutter wrapper.
#
# `default` is the interactive development shell — emulator, AVDs and the
# Linux desktop target included; inside it, `flutter run` deploys to a
# device or the emulator. `ci` is the release shell the GitHub workflow
# builds with (see .github/workflows/release.yml): everything the default
# shell carries except the emulator side.
{ nixpkgs, rust-overlay }:
let
  # Android SDK binaries and flutter's Android engine artifacts are
  # x86_64-only, so there is no point exposing other systems.
  forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" ];
in
{
  devShells = forAllSystems (
    system:
    let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ rust-overlay.overlays.default ];
        config = {
          allowUnfree = true; # Android SDK components are unfree
          # Accepted license hashes are written into the SDK at build
          # time, so `flutter doctor --android-licenses` passes without
          # prompts (the store path is read-only afterwards).
          android_sdk.accept_license = true;
        };
      };
      inherit (pkgs) lib;

      android = import ./android.nix { inherit pkgs lib; };
      rust = import ./rust.nix { inherit pkgs; };
      flutter = import ./flutter.nix { inherit pkgs; };

      jdk = pkgs.jdk; # AGP 8/9 requires JDK 17+

      # rust_builder/linux exists, so the Linux desktop target is used.
      linuxDesktop = true;
    in
    {
      default = pkgs.mkShell {
        packages = [
          flutter.flutterGradle9 # bundles dart + engine artifacts; PUB_CACHE → ~/.pub-cache
          pkgs.git # required by the flutter tool itself
          android.androidSdk # adb, sdkmanager, avdmanager, emulator, ndk on PATH
          jdk
          rust.rustToolchain # declarative rust: rustc, cargo, clippy, rustfmt
          rust.rustupShim # satisfies cargokit's rustup invocations
          # rquickjs generates bindings for Android ABIs that do not
          # have pre-generated bindings in the crate release. bindgen
          # only needs libclang.so, which it finds through
          # LIBCLANG_PATH below — the package itself must NOT go on
          # PATH: it propagates the *unwrapped* clang binaries, which
          # would sit ahead of the wrapped pkgs.clang and win every
          # `clang++` PATH lookup. flutter_tools hard-codes
          # CC=clang/CXX=clang++ for its CMake invocation
          # (build_linux.dart), so an unwrapped clang++ picked up that
          # way cannot link anything on NixOS (no glibc crt files or
          # libstdc++ paths) and the build dies at the compiler test
          # with "cannot find Scrt1.o" / "-lstdc++".
          # Binding generator (`flutter_rust_bridge_codegen generate`).
          # Its version must match the flutter_rust_bridge runtime in
          # pubspec.lock; after a nix flake update that bumps this
          # package, run `flutter pub upgrade flutter_rust_bridge`.
          pkgs.flutter_rust_bridge_codegen
          # The codegen expands macros before parsing the Rust sources
          # and shells out to `cargo expand`. Providing it here prevents
          # the codegen from imperatively `cargo install`-ing it into
          # ~/.cargo/bin on first run.
          pkgs.cargo-expand
        ]
        ++ lib.optionals linuxDesktop [
          # `flutter run -d linux` build dependencies. pkgs.clang is
          # the *wrapped* compiler: flutter_tools forces CXX=clang++
          # for its CMake invocation, so the first clang++ on PATH
          # must be this one (or the identical wrapper the nixpkgs
          # flutter wrapper suffixes to PATH), never a raw LLVM clang.
          pkgs.clang
          pkgs.cmake
          pkgs.libepoxy
          pkgs.ninja
          pkgs.pcre
          pkgs.pkg-config
          pkgs.gtk3
          # desktop_webview_window (the Linux login window) builds
          # against WebKitGTK 4.1: pkg-config webkit2gtk-4.1 + libsoup-3.0.
          pkgs.webkitgtk_4_1
        ];

        JAVA_HOME = jdk.home;
        ANDROID_HOME = "${android.androidSdk}/libexec/android-sdk";
        ANDROID_SDK_ROOT = "${android.androidSdk}/libexec/android-sdk"; # legacy tools still read this
        # bindgen (rquickjs) loads libclang.so from here — see the
        # note in `packages` for why libclang stays off PATH.
        LIBCLANG_PATH = "${pkgs.libclang.lib}/lib";

        # Do not inherit a bare host CC/CXX (for example an unwrapped
        # clang from the caller). QuickJS compiles bundled C sources and
        # therefore needs the Nix compiler wrapper to inject libc paths.
        # Android Native Assets sets target-specific NDK compilers, and
        # cargo-xwin likewise supplies its own MSVC target toolchain.
        CC = "${pkgs.stdenv.cc}/bin/cc";
        CXX = "${pkgs.stdenv.cc}/bin/c++";

        # WebKitGTK loads its GIO TLS backend from here; without it every
        # https load in the login window fails with "TLS support is not
        # available" (glib-networking is not part of the default profile).
        GIO_EXTRA_MODULES = "${pkgs.glib-networking}/lib/gio/modules";

        shellHook = ''
          # Some packages (notably the clang wrapper used by Flutter)
          # install setup hooks after mkShell variables and replace
          # CC/CXX. Restore the wrappers at the final hook stage.
          export CC="${pkgs.stdenv.cc}/bin/cc"
          export CXX="${pkgs.stdenv.cc}/bin/c++"

          # Tools installed with `cargo install` (e.g.
          # flutter_rust_bridge_codegen) land in ~/.cargo/bin.
          export PATH="''${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"

          # AGP downloads an unpatched aapt2 from Maven, which cannot
          # run on NixOS. Point Gradle at the auto-patched copy inside
          # the SDK (newest build-tools wins).
          aapt2="$(ls -d "$ANDROID_HOME"/build-tools/*/aapt2 | sort -V | tail -1)"
          export GRADLE_OPTS="''${GRADLE_OPTS:-} -Dorg.gradle.project.android.aapt2FromMavenOverride=$aapt2"

          # AVDs live in .avd/ at the project root (git toplevel,
          # falling back to the working directory) instead of
          # ~/.android/avd. Set ANDROID_AVD_HOME to override.
          project_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
          export ANDROID_AVD_HOME="''${ANDROID_AVD_HOME:-$project_root/.avd}"
          mkdir -p "$ANDROID_AVD_HOME"

          # Materialize the nix-built AVDs (see android.nix) into the
          # writable AVD home: the emulator creates lock files,
          # userdata and snapshots inside each .avd directory, so the
          # read-only store copies cannot be used in place.
          # avdmanager bakes the store path into the pointer .ini,
          # so the materialized copy gets its path line rewritten.
          # Materialization happens when an AVD directory is missing;
          # delete .avd/<name>.avd to re-materialize it from the
          # current nix definition.
          ${lib.concatMapStrings (avd: ''
            if [ ! -d "$ANDROID_AVD_HOME/${avd.name}.avd" ]; then
              echo "Materializing AVD ${avd.name}..."
              sed "s|^path=.*|path=$ANDROID_AVD_HOME/${avd.name}.avd|" \
                "${android.androidAvds}/${avd.name}.ini" \
                > "$ANDROID_AVD_HOME/${avd.name}.ini"
              cp -R "${android.androidAvds}/${avd.name}.avd" \
                "$ANDROID_AVD_HOME/${avd.name}.avd"
              chmod -R u+w "$ANDROID_AVD_HOME/${avd.name}.avd"
            fi
          '') android.avds}
        '';
      };

      # Release shell for CI (`nix develop .#ci`): the default shell
      # minus everything only a developer machine needs — the
      # emulator-side SDK, system images and AVD materialization are
      # gone (see androidSdkCi in android.nix). Used by the release
      # workflow's bindings and Android jobs so both build with exactly
      # the toolchain this flake pins — Flutter, the Rust toolchain with
      # the rustup shim native_toolchain_rust drives, libclang for
      # rquickjs's bindgen, the JDK and an Android SDK with the NDK
      # and pre-accepted licenses — instead of whatever the runner
      # image happens to carry. Linux desktop builds stay out of this
      # shell on purpose: a bundle linked against the nix-store
      # gtk/webkit only runs on machines with /nix, so the release
      # workflow keeps building the Linux tarball against the
      # runner's system libraries.
      ci = pkgs.mkShell {
        packages = [
          flutter.flutterGradle9
          pkgs.git
          android.androidSdkCi # adb, sdkmanager, ndk on PATH — no emulator
          jdk
          rust.rustToolchain
          rust.rustupShim
          # Bindings generation (release "Generate bindings" job).
          # The version is pinned by flake.lock and must match the
          # flutter_rust_bridge runtime in pubspec.lock; see the note
          # on the default shell.
          pkgs.flutter_rust_bridge_codegen
          pkgs.cargo-expand
        ];

        JAVA_HOME = jdk.home;
        ANDROID_HOME = "${android.androidSdkCi}/libexec/android-sdk";
        ANDROID_SDK_ROOT = "${android.androidSdkCi}/libexec/android-sdk"; # legacy tools still read this
        # bindgen (rquickjs) loads libclang.so from here — see the
        # note in the default shell for why libclang stays off PATH.
        LIBCLANG_PATH = "${pkgs.libclang.lib}/lib";

        # Same as the default shell: no bare host CC/CXX, and the
        # Android Native Assets build sets its own NDK compilers per
        # target.
        CC = "${pkgs.stdenv.cc}/bin/cc";
        CXX = "${pkgs.stdenv.cc}/bin/c++";

        shellHook = ''
          # Some packages install setup hooks after mkShell variables
          # and replace CC/CXX; restore the wrappers at the final hook
          # stage, exactly like the default shell.
          export CC="${pkgs.stdenv.cc}/bin/cc"
          export CXX="${pkgs.stdenv.cc}/bin/c++"

          # Tools installed with `cargo install` land in ~/.cargo/bin.
          export PATH="''${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"

          # AGP downloads an unpatched aapt2 from Maven; point Gradle
          # at the patched copy inside the SDK (newest build-tools
          # wins). Unnecessary on a plain Ubuntu runner, required
          # wherever the host is NixOS — kept for parity with the
          # default shell.
          aapt2="$(ls -d "$ANDROID_HOME"/build-tools/*/aapt2 | sort -V | tail -1)"
          export GRADLE_OPTS="''${GRADLE_OPTS:-} -Dorg.gradle.project.android.aapt2FromMavenOverride=$aapt2"
        '';
      };
    }
  );
}

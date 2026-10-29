# Langhuan dev shell: Flutter + Android SDK + Rust (flutter_rust_bridge).
#
# Based on the flutter template from ~/nixos-config. The SDK is composed
# from two androidenv builds merged into one root: a build side carrying
# every platform AGP must find — the compileSdk levels the app and the
# Android plugins declare (35, 36) — plus the NDK pinned by Flutter 3.47
# for the Rust cross builds, and an emulator side carrying only the API 36
# system image the AVD boots plus the emulator itself. androidenv
# cross-products system images with platforms, so a single composition
# would pull a > 4 GB image for every build platform; the split keeps the
# image list pinned to what the AVD actually boots. A mutable SDK would
# auto-install the extra platforms on demand; the read-only nix store
# cannot, so they are declared here. The AVDs themselves are store
# artifacts too: avdmanager runs at build time against the emulator-side
# SDK and the shell materializes the read-only result into a writable AVD
# home, because the emulator must create lock files, userdata and
# snapshots inside each .avd directory.
# The Rust toolchain is fully declarative: oxalica/rust-overlay provides a
# prebuilt stable toolchain (pinned by flake.lock) with the Android
# cross-targets the Native Assets build hook compiles for, and a small
# `rustup` shim satisfies native_toolchain_rust's insistence on driving
# builds through rustup.
# Inside the shell, `flutter run` deploys to a device or the emulator.
{
  description = "Langhuan development environment (Flutter + Rust + Android)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Prebuilt Rust toolchains with per-target overrides; pinned by
    # flake.lock like every other input.
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      rust-overlay,
      ...
    }:
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
          # AVD home on first shell entry.
          # `avdmanager list device` prints all available device ids.
          avds = [
            {
              name = "Pixel_7_API_36";
              device = "pixel_7";
              package = "system-images;android-36;google_apis;x86_64";
            }
          ];

          # rust_builder/linux exists, so the Linux desktop target is used.
          linuxDesktop = true;
          # ─────────────────────────────────────────────────────────────────

          # Stable Rust (rustc, cargo, clippy, rustfmt) with the Android
          # targets cargokit cross-compiles to; the host target is always
          # included for the linux desktop build. The rust-analyzer and
          # rust-src components make editors launched inside the shell
          # analyze with this exact toolchain: the LSP server binary is
          # built for the pinned rustc release, and rust-src provides the
          # standard library sources rust-analyzer needs for std analysis.
          rustToolchain = pkgs.rust-bin.stable.latest.default.override {
            extensions = [
              "rust-analyzer"
              "rust-src"
            ];
            targets = [
              "aarch64-linux-android"
              "armv7-linux-androideabi"
              "i686-linux-android"
              "x86_64-linux-android"
              # Lets Linux CI/cargo-xwin type-check the native QuickJS path
              # against the same MSVC ABI used by Flutter Windows builds.
              "x86_64-pc-windows-msvc"
            ];
          };

          # Both the old Cargokit integration and the current Native Assets
          # builder (native_toolchain_rust, driving `cargo build` for
          # hook/build.dart) insist on driving builds through a `rustup`
          # executable. This shim satisfies their exact call surface with
          # the declarative toolchain above:
          #   - `run <toolchain> <command...>` executes the command directly
          #   - `show active-toolchain` reports the nix rustc as active
          #   - toolchain/target/component management is a successful no-op
          #   - queries report what the nix toolchain actually contains
          rustupShim = pkgs.writeShellScriptBin "rustup" ''
            set -eu

            case "''${1-}" in
              run)
                # `rustup run <toolchain> <command...>` → `<command...>`
                shift 2
                exec "$@"
                ;;
              show)
                case "''${2-}" in
                  active-toolchain)
                    # Mirror the real rustup's "<channel>-<host> (default)"
                    # line; callers only log the output, but keep it truthful.
                    echo "$(rustc --version | sed -n 's/^rustc \([0-9][0-9.]*\).*/\1/p')-$(rustc -vV | sed -n 's/^host: //p') (default)"
                    ;;
                  *)
                    echo "rustup shim: unsupported command: $*" >&2
                    exit 1
                    ;;
                esac
                ;;
              toolchain)
                case "''${2-}" in
                  list)
                    echo "$(rustc --version | sed -n 's/^rustc \([0-9][0-9.]*\).*/\1/p')-$(rustc -vV | sed -n 's/^host: //p') (default)"
                    ;;
                  install)
                    # Toolchains come from the nix store; nothing to install.
                    echo "rustup shim: toolchains are provided by nix, ignoring: $*" >&2
                    ;;
                  *)
                    echo "rustup shim: unsupported command: $*" >&2
                    exit 1
                    ;;
                esac
                ;;
              target)
                case "''${2-}" in
                  list)
                    # Report the std targets the nix toolchain carries.
                    sysroot="$(rustc --print sysroot 2>/dev/null || true)"
                    if [ -d "$sysroot/lib/rustlib" ]; then
                      ls "$sysroot/lib/rustlib" | grep -vxE '(lib|src|bin|etc)' || true
                    fi
                    ;;
                  add)
                    echo "rustup shim: targets are provided by nix, ignoring: $*" >&2
                    ;;
                  *)
                    echo "rustup shim: unsupported command: $*" >&2
                    exit 1
                    ;;
                esac
                ;;
              component)
                # Only ever used to fetch rust-src for nightly builds;
                # the declarative toolchain decides what is available.
                echo "rustup shim: components are provided by nix, ignoring: $*" >&2
                ;;
              *)
                echo "rustup shim: unsupported command: $*" >&2
                exit 1
                ;;
            esac
          '';

          jdk = pkgs.jdk; # AGP 8/9 requires JDK 17+

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
              # the merge below.
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
          # which is why includeCMake = false keeps the package out
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

          # One SDK root for ANDROID_HOME and PATH: the build SDK
          # wholesale, plus the emulator and system images from the
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

          # CI/release SDK root: the build-side composition plus the same
          # cmake/3.22.1 merge as above, but none of the emulator side —
          # no emulator, no system images, no AVD machinery. Release
          # runners never boot a device, and skipping that side keeps the
          # ~2 GB image closure out of every cold `nix develop .#ci`.
          androidSdkCi = pkgs.runCommand "androidsdk-ci" { } ''
            mkdir -p $out/libexec/android-sdk $out/bin
            for entry in ${androidSdkBuild}/libexec/android-sdk/*; do
              ln -s "$entry" "$out/libexec/android-sdk/$(basename "$entry")"
            done
            for tool in ${androidSdkBuild}/bin/*; do
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
        in
        {
          default = pkgs.mkShell {
            packages = [
              flutterGradle9 # bundles dart + engine artifacts; PUB_CACHE → ~/.pub-cache
              pkgs.git # required by the flutter tool itself
              androidSdk # adb, sdkmanager, avdmanager, emulator, ndk on PATH
              jdk
              rustToolchain # declarative rust: rustc, cargo, clippy, rustfmt
              rustupShim # satisfies cargokit's rustup invocations
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
            ANDROID_HOME = "${androidSdk}/libexec/android-sdk";
            ANDROID_SDK_ROOT = "${androidSdk}/libexec/android-sdk"; # legacy tools still read this
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

              # Materialize the nix-built AVDs (see androidAvds) into the
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
                    "${androidAvds}/${avd.name}.ini" \
                    > "$ANDROID_AVD_HOME/${avd.name}.ini"
                  cp -R "${androidAvds}/${avd.name}.avd" \
                    "$ANDROID_AVD_HOME/${avd.name}.avd"
                  chmod -R u+w "$ANDROID_AVD_HOME/${avd.name}.avd"
                fi
              '') avds}
            '';
          };

          # Release shell for CI (`nix develop .#ci`): the default shell
          # minus everything only a developer machine needs — the
          # emulator-side SDK, system images and AVD materialization are
          # gone (see androidSdkCi). Used by the release workflow's
          # bindings and Android jobs so both build with exactly the
          # toolchain this flake pins — Flutter, the Rust toolchain with
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
              flutterGradle9
              pkgs.git
              androidSdkCi # adb, sdkmanager, ndk on PATH — no emulator
              jdk
              rustToolchain
              rustupShim
              # Bindings generation (release "Generate bindings" job).
              # The version is pinned by flake.lock and must match the
              # flutter_rust_bridge runtime in pubspec.lock; see the note
              # on the default shell.
              pkgs.flutter_rust_bridge_codegen
              pkgs.cargo-expand
            ];

            JAVA_HOME = jdk.home;
            ANDROID_HOME = "${androidSdkCi}/libexec/android-sdk";
            ANDROID_SDK_ROOT = "${androidSdkCi}/libexec/android-sdk"; # legacy tools still read this
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
    };
}

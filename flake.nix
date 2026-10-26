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
# cannot, so they are declared here.
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

          # AVDs provisioned automatically on first entry.
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
              # have pre-generated bindings in the crate release.
              pkgs.libclang
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
              # `flutter run -d linux` build dependencies
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
              # Some packages (notably the unwrapped clang executable used
              # by Flutter) install setup hooks after mkShell variables and
              # replace CC/CXX. Restore the wrappers at the final hook stage.
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

              # Create declared AVDs that do not exist yet. The
              # composition carries the emulator and the system images
              # ANDROID_HOME points at, so plain avdmanager works.
              ${lib.concatMapStrings (avd: ''
                if [ ! -d "$ANDROID_AVD_HOME/${avd.name}.avd" ]; then
                  echo "Creating AVD ${avd.name}..."
                  echo no | avdmanager create avd -n "${avd.name}" -k "${avd.package}" -d "${avd.device}"
                fi
              '') avds}
            '';
          };
        }
      );
    };
}

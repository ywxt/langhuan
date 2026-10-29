# The Rust toolchain is fully declarative: oxalica/rust-overlay provides a
# prebuilt stable toolchain (pinned by flake.lock) with the Android
# cross-targets the Native Assets build hook compiles for, and a small
# `rustup` shim satisfies native_toolchain_rust's insistence on driving
# builds through rustup.
{ pkgs }:
let
  # Stable Rust (rustc, cargo, clippy, rustfmt) plus the requested
  # cross-targets; the host target is always included by the overlay.
  # The rust-analyzer and rust-src components make editors launched
  # inside a shell analyze with this exact toolchain: the LSP server
  # binary is built for the pinned rustc release, and rust-src provides
  # the standard library sources rust-analyzer needs for std analysis.
  mkRustToolchain =
    targets:
    pkgs.rust-bin.stable.latest.default.override {
      extensions = [
        "rust-analyzer"
        "rust-src"
      ];
      inherit targets;
    };
in
{
  inherit mkRustToolchain;

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
}

# macOS release shell for CI (`nix develop .#ci` on aarch64-darwin), used
# by the release workflow's macOS job. It builds with the toolchain this
# flake pins — flutter, the Rust toolchain (with the rustup shim
# native_toolchain_rust drives) and libclang for rquickjs's bindgen — so
# the macOS artifacts cannot drift from what local development uses.
#
# There is no `default` shell here: interactive development happens on
# Linux, and the Android SDK machinery the default shell carries is
# x86_64-linux only anyway.
#
# Xcode is deliberately NOT part of this shell: `flutter build macos`
# drives xcodebuild, Apple licenses its toolchain to the machine, and nix
# cannot ship it — the runner provides it. CC/CXX therefore stay unset so
# the QuickJS C compilation resolves the runner's Xcode clang, exactly
# like the pre-nix job did.
{ pkgs }:
let
  rust = import ../rust.nix { inherit pkgs; };

  # Host toolchain (aarch64-apple-darwin) only: the macOS job builds no
  # Android or cross targets. Bound in a let because a function
  # application inside a list literal does not parse as one element
  # (`rust.mkRustToolchain [ ]` there would yield the function itself
  # followed by an empty list).
  rustToolchain = rust.mkRustToolchain [ ];
in
{
  ci = pkgs.mkShell {
    packages = [
      # Plain nixpkgs flutter — the gradle patches in ../flutter.nix
      # are Android-build concerns and `flutter build macos` never
      # touches gradle; the plain wrapper also avoids assuming the
      # patched paths exist in the darwin build of flutter_tools.
      pkgs.flutter # bundles dart + engine artifacts; PUB_CACHE → ~/.pub-cache
      pkgs.git # required by the flutter tool itself
      rustToolchain
      rust.rustupShim
      # Bindings land via the generated-bindings artifact, but pub get
      # and the native-assets hook still need the codegen present.
      pkgs.flutter_rust_bridge_codegen
      pkgs.cargo-expand
    ];

    # bindgen (rquickjs) loads libclang.so from here; like on Linux,
    # the libclang package stays off PATH so it cannot shadow any
    # compiler the shell may find there.
    LIBCLANG_PATH = "${pkgs.libclang.lib}/lib";

    shellHook = ''
      # Tools installed with `cargo install` land in ~/.cargo/bin.
      export PATH="''${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
    '';
  };
}

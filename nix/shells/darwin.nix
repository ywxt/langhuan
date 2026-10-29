# macOS release shell for CI (`nix develop .#ci` on aarch64-darwin), used
# by the release workflow's macOS job. The flake pins the parts that are
# version-sensitive and cheap to substitute — the Rust toolchain (with
# the rustup shim native_toolchain_rust drives) and libclang for
# rquickjs's bindgen — so they cannot drift from what local development
# and the Android builds use.
#
# There is no `default` shell here: interactive development happens on
# Linux, and the Android SDK machinery the default shell carries is
# x86_64-linux only anyway.
#
# flutter deliberately stays OUT of this shell. nixpkgs' darwin flutter
# cannot build macOS apps as-is: its engine artifacts live in the
# (immutable) nix store with read-only directory modes, and xcodebuild's
# ditto copy preserves them, so the release_unpack_macos phase fails
# with "lipo: can't create temporary output file ... (Permission
# denied)" when it thins FlutterMacOS.framework inside the build tree.
# The workflow therefore uses subosito/flutter-action, whose SDK is
# writable, and this shell provides everything else around it.
#
# Xcode is likewise not part of the shell — Apple licenses its toolchain
# to the machine and nix cannot ship it — but note that a darwin
# mkShell puts the nix stdenv's cctools/clang wrappers at the FRONT of
# PATH (that is how the nix lipo got picked above). CC/CXX are pinned to
# the runner's Xcode compilers below so the QuickJS C compilation
# behaves exactly like the pre-nix job did, instead of silently picking
# the stdenv wrapper.
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
      pkgs.git # required by the flutter tool itself
      rustToolchain
      rust.rustupShim
      # Bindings land via the generated-bindings artifact; kept for
      # parity with the Linux ci shell (cheap, cache-substitutable).
      pkgs.flutter_rust_bridge_codegen
      pkgs.cargo-expand
    ];

    # bindgen (rquickjs) loads libclang.so from here; like on Linux,
    # the libclang package stays off PATH so it cannot shadow any
    # compiler the shell may find there.
    LIBCLANG_PATH = "${pkgs.libclang.lib}/lib";

    # Xcode's compilers, not the nix stdenv wrappers — see the header
    # comment. Absolute paths, so no PATH lookup is involved.
    CC = "/usr/bin/cc";
    CXX = "/usr/bin/c++";

    shellHook = ''
      # Tools installed with `cargo install` land in ~/.cargo/bin.
      export PATH="''${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
    '';
  };
}

# Langhuan dev shells: Flutter + Android SDK + Rust (flutter_rust_bridge).
#
# Based on the flutter template from ~/nixos-config. The shell logic is
# split into modules under nix/:
#
#   nix/shells.nix  — the dev shells themselves: `default` for
#                     interactive development (emulator, AVDs, the
#                     Linux desktop target), `ci` for the release
#                     workflow
#   nix/android.nix — the Android SDK compositions (build / emulator /
#                     CI sides) and the AVDs
#   nix/rust.nix    — the declarative Rust toolchain and rustup shim
#   nix/flutter.nix — the nixpkgs flutter wrapper patched for Gradle 9
#
# Inside the default shell, `flutter run` deploys to a device or the
# emulator. `nix develop .#ci` is what the release workflow builds with.
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
    { nixpkgs, rust-overlay, ... }:
    import ./nix/shells.nix { inherit nixpkgs rust-overlay; };
}

# Langhuan dev shell: Flutter + Android SDK + Rust (flutter_rust_bridge).
#
# Based on the flutter template from ~/nixos-config. The shell logic is
# split into modules under nix/:
#
#   nix/shells.nix  — the dev shell itself: `default` for interactive
#                     development (emulator, AVDs, the Linux desktop
#                     target)
#   nix/android.nix — the Android SDK compositions (build / emulator
#                     sides) and the AVDs
#   nix/rust.nix    — the declarative Rust toolchain and rustup shim
#   nix/flutter.nix — the nixpkgs flutter wrapper patched for Gradle 9
#
# Inside the default shell, `flutter run` deploys to a device or the
# emulator. This flake is development-only: release builds use the
# runner's native toolchains (see .github/workflows/release.yml).
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

# Per-system composition of the dev shells. The system list is explicit:
# the Android SDK binaries and flutter's Android engine artifacts are
# x86_64-linux only, and the macOS release shell exists for
# aarch64-darwin alone because the release ships an arm64 build (the
# Intel macOS job is gone; see darwin.nix for why that shell carries
# no flutter).
# The shells themselves live in sibling files: linux.nix (`default` for
# interactive development, `ci` for the release workflow's bindings and
# Android jobs) and darwin.nix (`ci` for the macOS job).
{ nixpkgs, rust-overlay }:
let
  mkPkgs =
    system:
    import nixpkgs {
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
in
{
  devShells = {
    x86_64-linux = import ./linux.nix { pkgs = mkPkgs "x86_64-linux"; };

    aarch64-darwin = import ./darwin.nix { pkgs = mkPkgs "aarch64-darwin"; };
  };
}

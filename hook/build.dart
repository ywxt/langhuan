import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    await FlutterRustBridgeNativeAssetsBuilder(
      cratePath: 'native/hub',
      extraCargoEnvironmentVariables: _androidBindgenEnvironment(input),
    ).run(input: input, output: output);
  });
}

/// Prevents Nix host headers from leaking into Android bindgen invocations.
///
/// `native_toolchain_rust` already supplies the Android sysroot and target
/// include directory. Nix's libclang additionally injects its Linux glibc
/// headers, however, which makes bindgen parse `gnu/stubs.h` for the wrong
/// platform. Use the NDK compiler bundled in the build input to make Android
/// header lookup hermetic in every Flutter build mode.
Map<String, String> _androidBindgenEnvironment(BuildInput input) {
  if (!input.config.buildCodeAssets) return const {};
  final codeConfig = input.config.code;
  final isNixHost =
      Platform.isLinux &&
      (Platform.environment.containsKey('IN_NIX_SHELL') ||
          Platform.environment.containsKey('NIX_CFLAGS_COMPILE'));
  if (codeConfig.targetOS != OS.android || !isNixHost) return const {};

  final target = switch (codeConfig.targetArchitecture) {
    Architecture.arm => 'armv7-linux-androideabi',
    Architecture.arm64 => 'aarch64-linux-android',
    Architecture.x64 => 'x86_64-linux-android',
    final architecture => throw UnsupportedError(
      'Unsupported Android architecture: $architecture',
    ),
  };

  final compiler = codeConfig.cCompiler?.compiler;
  if (compiler == null) {
    throw StateError('Android Native Assets build has no NDK compiler');
  }

  final compilerFile = File.fromUri(compiler);
  final llvmRoot = compilerFile.parent.parent;
  final sysroot = Directory('${llvmRoot.path}/sysroot');
  final clangRoot = Directory('${llvmRoot.path}/lib/clang');
  final resourceIncludes =
      clangRoot
          .listSync()
          .whereType<Directory>()
          .map((version) => Directory('${version.path}/include'))
          .where((directory) => directory.existsSync())
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  if (resourceIncludes.isEmpty) {
    throw StateError(
      'Cannot locate Android NDK Clang resource headers under '
      '${clangRoot.path}',
    );
  }

  final sysrootTarget = target == 'armv7-linux-androideabi'
      ? 'arm-linux-androideabi'
      : target;
  final targetEnv = target.replaceAll('-', '_');
  final bindgenArgs = [
    '--sysroot=${sysroot.path}',
    '-I${sysroot.path}/usr/include/$sysrootTarget',
    '-nostdinc',
    '-isystem',
    resourceIncludes.last.path,
    '-isystem',
    '${sysroot.path}/usr/include',
  ].join(' ');

  return {
    'BINDGEN_EXTRA_CLANG_ARGS_$targetEnv': bindgenArgs,
    'NIX_CFLAGS_COMPILE': '',
    'NIX_CFLAGS_COMPILE_FOR_BUILD': '',
  };
}

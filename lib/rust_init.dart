import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/src/bindings/signals/signals.dart';
import 'package:path_provider/path_provider.dart';

Future<Directory> _getScriptDirPath() async {
  final docsDir = await getApplicationDocumentsDirectory();
  final scriptsDir = Directory('${docsDir.path}/scripts');
  await scriptsDir.create(recursive: true);
  return scriptsDir;
}

void _sendLocale() {
  SetLocale(
    locale: SchedulerBinding.instance.platformDispatcher.locale.toLanguageTag(),
  ).sendSignalToRust();
}

void setLocaleToRust() {
  // Send the current system locale to Rust, and keep it updated if the
  // user changes their system language while the app is running.
  _sendLocale();
  SchedulerBinding.instance.platformDispatcher.onLocaleChanged = _sendLocale;
}

final scriptDirectorySetProvider = FutureProvider<ScriptDirectorySet>((
  ref,
) async {
  final path = (await _getScriptDirPath()).path;
  return FeedService.instance.setScriptDirectory(path);
});

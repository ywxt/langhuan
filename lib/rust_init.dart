import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/src/bindings/signals/signals.dart';
import 'package:path_provider/path_provider.dart';

Future<Directory> _getAppDataDirectory() async {
  return getApplicationDocumentsDirectory();
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

final appDataDirectorySetProvider = FutureProvider<AppDataDirectorySet>((
  ref,
) async {
  final path = (await _getAppDataDirectory()).path;
  return FeedService.instance.setAppDataDirectory(path);
});

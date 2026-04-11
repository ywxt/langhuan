import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:langhuan/shared/app_service.dart';
import 'package:path_provider/path_provider.dart';

Future<Directory> _getAppDataDirectory() async {
  return getApplicationDocumentsDirectory();
}

void _sendLocale() {
  AppService.instance.setLocale(
    SchedulerBinding.instance.platformDispatcher.locale.toLanguageTag(),
  );
}

void setLocaleToRust() {
  // Send the current system locale to Rust, and keep it updated if the
  // user changes their system language while the app is running.
  _sendLocale();
  SchedulerBinding.instance.platformDispatcher.onLocaleChanged = _sendLocale;
}

/// Result of setting the app data directory.
///
/// [feedCount] is the number of feeds loaded from the registry.
class AppDataDirectoryResult {
  const AppDataDirectoryResult({required this.feedCount});
  final int feedCount;
}

final appDataDirectorySetProvider = FutureProvider<AppDataDirectoryResult>((
  ref,
) async {
  final path = (await _getAppDataDirectory()).path;
  final feedCount = await AppService.instance.setAppDataDirectory(path);
  return AppDataDirectoryResult(feedCount: feedCount);
});

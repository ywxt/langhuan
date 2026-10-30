import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Small structured logger for Dart-side lifecycle and performance events.
///
/// Keep fields free of credentials and response bodies: these messages are
/// visible in `flutter run` and may be copied into bug reports.
abstract final class AppLog {
  static void debug(
    String scope,
    String message, {
    Map<String, Object?> fields = const {},
  }) {
    _write(scope, message, fields: fields, level: 500);
  }

  static void info(
    String scope,
    String message, {
    Map<String, Object?> fields = const {},
  }) {
    _write(scope, message, fields: fields, level: 800);
  }

  static void warning(
    String scope,
    String message, {
    Map<String, Object?> fields = const {},
    Object? error,
    StackTrace? stackTrace,
  }) {
    _write(
      scope,
      message,
      fields: fields,
      level: 900,
      error: error,
      stackTrace: stackTrace,
    );
  }

  static void _write(
    String scope,
    String message, {
    required Map<String, Object?> fields,
    required int level,
    Object? error,
    StackTrace? stackTrace,
  }) {
    final suffix = fields.entries
        .where((entry) => entry.value != null)
        .map((entry) => '${entry.key}=${_format(entry.value)}')
        .join(' ');
    final rendered = suffix.isEmpty ? message : '$message $suffix';
    developer.log(
      rendered,
      name: 'langhuan.$scope',
      level: level,
      error: error,
      stackTrace: stackTrace,
    );
    // `dart:developer` is available in DevTools, but Linux profile builds do
    // not mirror it to the `flutter run` terminal. Keep profile diagnostics
    // directly observable without adding release-build noise.
    if (kProfileMode) debugPrint('[langhuan.$scope] $rendered');
  }

  static String _format(Object? value) {
    final text = value.toString().replaceAll(RegExp(r'\s+'), ' ');
    return text.contains(' ') ? '"$text"' : text;
  }
}

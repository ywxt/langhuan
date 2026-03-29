import 'dart:async';

import 'package:flutter/material.dart';

/// Shows an undo snackbar and waits for the user to tap "Undo" or for the
/// [duration] to expire.
///
/// Returns `true` if the user tapped Undo, `false` if the timer expired.
///
/// The caller is responsible for the actual deletion and any state updates.
Future<bool> deleteWithUndo({
  required ScaffoldMessengerState messenger,
  required String message,
  required String undoLabel,
  Duration duration = const Duration(seconds: 4),
}) async {
  final completer = Completer<bool>();

  messenger.clearSnackBars();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      action: SnackBarAction(
        label: undoLabel,
        onPressed: () {
          if (!completer.isCompleted) completer.complete(true);
        },
      ),
      duration: duration,
    ),
  );

  final timer = Timer(duration, () {
    if (!completer.isCompleted) completer.complete(false);
  });

  final undone = await completer.future;
  timer.cancel();
  return undone;
}

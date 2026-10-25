import 'package:flutter/material.dart';

/// Shows a success snackbar with a leading check icon.
ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showSuccessSnack(
  ScaffoldMessengerState messenger,
  String message,
) {
  return _showSnack(messenger, message, Icons.check_circle_outline);
}

/// Shows an error snackbar with a leading error icon.
ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showErrorSnack(
  ScaffoldMessengerState messenger,
  String message, {
  Duration duration = const Duration(seconds: 4),
}) {
  return _showSnack(
    messenger,
    message,
    Icons.error_outline,
    duration: duration,
  );
}

ScaffoldFeatureController<SnackBar, SnackBarClosedReason> _showSnack(
  ScaffoldMessengerState messenger,
  String message,
  IconData icon, {
  Duration duration = const Duration(seconds: 4),
}) {
  final theme = Theme.of(messenger.context);
  messenger.hideCurrentSnackBar();
  return messenger.showSnackBar(
    SnackBar(
      content: Row(
        children: [
          Icon(icon, color: theme.colorScheme.onInverseSurface),
          const SizedBox(width: 12),
          Expanded(child: Text(message)),
        ],
      ),
      duration: duration,
    ),
  );
}

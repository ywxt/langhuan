import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A reusable error-state placeholder following the Wise design spec §5.4.
///
/// Shows an error [icon], a [title], an optional [message] with detail text,
/// and an optional [onRetry] callback that renders a "Retry" tonal button.
class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.title,
    this.message,
    this.onRetry,
    this.retryLabel,
  });

  /// Error headline (Body Bold, `sentiment.negative`).
  final String title;

  /// Longer description (Body Default, `content.secondary`).
  final String? message;

  /// If non-null a tonal retry button is shown.
  final VoidCallback? onRetry;

  /// Label for the retry button. Defaults to "Retry" via caller.
  final String? retryLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(LanghuanTheme.spaceXl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: theme.colorScheme.error.withAlpha(160),
            ),
            const SizedBox(height: LanghuanTheme.spaceMd),
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            if (message != null) ...[
              const SizedBox(height: LanghuanTheme.spaceSm),
              Text(
                message!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: LanghuanTheme.spaceMd),
              FilledButton.tonal(
                onPressed: onRetry,
                child: Text(retryLabel ?? 'Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

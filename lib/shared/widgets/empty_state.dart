import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A reusable empty-state placeholder following the Wise design spec §5.3.
///
/// Shows a large semi-transparent [icon], a [title], an optional [subtitle],
/// and an optional [action] button — all vertically centred.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  /// Icon displayed at the top (48–56px, tertiary colour at 40% opacity).
  final IconData icon;

  /// Primary message (Title Body style).
  final String title;

  /// Secondary message (Body Large, `content.secondary`).
  final String? subtitle;

  /// Optional action widget (e.g. a button) shown below the text.
  final Widget? action;

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
              icon,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant.withAlpha(100),
            ),
            const SizedBox(height: LanghuanTheme.spaceMd),
            Text(
              title,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: LanghuanTheme.spaceSm),
              Text(
                subtitle!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant.withAlpha(160),
                ),
                textAlign: TextAlign.center,
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: LanghuanTheme.spaceMd),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

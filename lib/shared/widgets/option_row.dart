import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A generic tappable row with icon, title, optional subtitle, and a trailing
/// widget (defaults to a chevron).
///
/// Extracted from the feed "source picker" sheet so it can be reused anywhere
/// a list of tappable options is needed.
class OptionRow extends StatelessWidget {
  const OptionRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback? onTap;

  /// Defaults to a chevron-right icon when `null`.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      borderRadius: LanghuanTheme.borderRadiusMd,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: LanghuanTheme.spaceMd,
          horizontal: LanghuanTheme.spaceSm,
        ),
        child: Row(
          children: [
            Icon(icon, size: 24, color: theme.colorScheme.primary),
            const SizedBox(width: LanghuanTheme.spaceMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: LanghuanTheme.spaceXs),
                    Text(
                      subtitle!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            trailing ??
                Icon(
                  Icons.chevron_right,
                  color: theme.colorScheme.onSurfaceVariant.withAlpha(120),
                ),
          ],
        ),
      ),
    );
  }
}

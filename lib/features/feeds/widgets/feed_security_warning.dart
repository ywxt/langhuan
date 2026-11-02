import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';

/// Persistent warning shown before a feed script can be installed.
class FeedSecurityWarning extends StatelessWidget {
  const FeedSecurityWarning({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    // Caution yellow rather than the scheme's error tones — the warning
    // flags a decision for the user (trust this source?), not a failure.
    final isDark = theme.brightness == Brightness.dark;
    final container = isDark
        ? LanghuanTheme.warningContainerDark
        : LanghuanTheme.warningContainerLight;
    final onContainer = isDark
        ? LanghuanTheme.onWarningContainerDark
        : LanghuanTheme.onWarningContainerLight;

    return Container(
      padding: const EdgeInsets.all(LanghuanTheme.spaceMd),
      decoration: BoxDecoration(
        color: container,
        borderRadius: LanghuanTheme.borderRadiusMd,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.gpp_maybe_outlined, color: onContainer),
          const SizedBox(width: LanghuanTheme.spaceMdSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.feedSecurityWarningTitle,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: onContainer,
                  ),
                ),
                const SizedBox(height: LanghuanTheme.spaceXs),
                Text(
                  l10n.feedSecurityWarningBody,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: onContainer,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';

/// Persistent warning shown before a feed script can be installed.
class FeedSecurityWarning extends StatelessWidget {
  const FeedSecurityWarning({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);

    return Container(
      padding: const EdgeInsets.all(LanghuanTheme.spaceMd),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: LanghuanTheme.borderRadiusMd,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.gpp_maybe_outlined, color: colors.onErrorContainer),
          const SizedBox(width: LanghuanTheme.spaceMdSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.feedSecurityWarningTitle,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: colors.onErrorContainer,
                  ),
                ),
                const SizedBox(height: LanghuanTheme.spaceXs),
                Text(
                  l10n.feedSecurityWarningBody,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onErrorContainer,
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

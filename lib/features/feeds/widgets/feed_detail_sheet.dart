import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/meta_row.dart';
import '../../../src/bindings/signals/signals.dart';

/// Opens a modal bottom sheet showing feed metadata.
void showFeedDetailSheet(BuildContext context, FeedMetaItem feed) {
  showModalBottomSheet<void>(
    context: context,
    builder: (context) => FeedDetailSheet(feed: feed),
  );
}

/// Bottom sheet displaying detailed metadata for a single feed.
class FeedDetailSheet extends StatelessWidget {
  const FeedDetailSheet({super.key, required this.feed});

  final FeedMetaItem feed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          LanghuanTheme.spaceLg,
          0,
          LanghuanTheme.spaceLg,
          LanghuanTheme.spaceXl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(feed.name, style: theme.textTheme.titleLarge),
            const SizedBox(height: LanghuanTheme.spaceMd),

            if (feed.error != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(LanghuanTheme.spaceMd),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: LanghuanTheme.borderRadiusMd,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 18,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: LanghuanTheme.spaceSm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.feedItemLoadError,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onErrorContainer,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            feed.error!,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onErrorContainer,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: LanghuanTheme.spaceMd),
            ],

            MetaRow(
              icon: Icons.label_outline,
              label: l10n.feedDetailId,
              value: feed.id,
            ),
            const SizedBox(height: LanghuanTheme.spaceMd),
            MetaRow(
              icon: Icons.tag,
              label: l10n.feedDetailVersion,
              value: feed.version,
            ),
            if (feed.author != null) ...[
              const SizedBox(height: LanghuanTheme.spaceMd),
              MetaRow(
                icon: Icons.person_outline,
                label: l10n.feedDetailAuthor,
                value: feed.author!,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/configuration_list_card.dart';
import '../../../shared/widgets/loading.dart';
import '../../../src/rust/api/types.dart';
import '../feed_providers.dart';
import '../feed_service.dart';
import 'feed_detail_sheet.dart';

/// Read-only identity and status summary, matching Transformer list rows.
/// Management actions are available in the detail sheet.
class FeedCard extends ConsumerWidget {
  const FeedCard({
    super.key,
    required this.feed,
    this.isDeleting = false,
    this.enabled = true,
    this.onDelete,
  });

  final FeedMetaItem feed;
  final bool isDeleting, enabled;
  final Future<void> Function()? onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);
    final hasError = feed.error != null;
    final auth = ref
        .watch(feedAuthStatusProvider((feedId: feed.id, isValid: !hasError)))
        .asData
        ?.value;
    final authLabel = switch (auth) {
      FeedAuthStatusModel.loggedIn => l.feedAuthStatusLoggedIn,
      FeedAuthStatusModel.expired => l.feedAuthStatusExpired,
      FeedAuthStatusModel.loggedOut => l.feedAuthStatusLoggedOut,
      _ => null,
    };
    final summary = [
      'v${feed.version}',
      if (feed.author case final author? when author.isNotEmpty) author,
      ?authLabel,
    ].join(' · ');
    return ConfigurationListCard(
      leading: Icon(Icons.extension_outlined),
      title: feed.name,
      subtitle: summary,
      status: isDeleting
          ? const LanghuanSpinner(size: 20)
          : Text(
              hasError
                  ? l.feedItemLoadError
                  : feed.enabled
                  ? l.feedDetailEnabled
                  : l.feedItemPaused,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: hasError
                    ? colors.error
                    : feed.enabled
                    ? colors.primary
                    : colors.onSurfaceVariant,
              ),
            ),
      onTap: isDeleting || !enabled
          ? null
          : () => showFeedDetailSheet(context, feed, onDelete: onDelete),
    );
  }
}

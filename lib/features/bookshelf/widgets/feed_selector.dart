import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../src/rust/api/types.dart';
import '../../feeds/feed_providers.dart';

/// Horizontal chip row for selecting a feed source on the search page.
class FeedSelector extends ConsumerWidget {
  const FeedSelector({
    super.key,
    required this.feedState,
    required this.visibleFeeds,
    required this.selectedFeed,
  });

  final FeedListState feedState;
  final List<FeedMetaItem> visibleFeeds;
  final FeedMetaItem? selectedFeed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    if (feedState.isLoading) {
      return const SizedBox(
        height: 48,
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (visibleFeeds.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LanghuanTheme.spaceLg,
          vertical: LanghuanTheme.spaceSm,
        ),
        child: Text(
          l10n.feedSelectorNoFeeds,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return SizedBox(
      height: 48,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: LanghuanTheme.spaceLg - 4,
          vertical: LanghuanTheme.spaceSm,
        ),
        itemCount: visibleFeeds.length,
        itemBuilder: (context, index) {
          final feed = visibleFeeds[index];
          final isSelected = selectedFeed?.id == feed.id;
          return Padding(
            padding: const EdgeInsets.only(right: LanghuanTheme.spaceSm),
            child: ChoiceChip(
              label: Text(
                feed.name,
                style: TextStyle(
                  color: isSelected
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.onSurface,
                ),
              ),
              selected: isSelected,
              onSelected: (_) =>
                  ref.read(selectedFeedProvider.notifier).select(feed),
            ),
          );
        },
      ),
    );
  }
}

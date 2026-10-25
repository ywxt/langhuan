import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/loading.dart';
import '../../../src/rust/api/types.dart';
import '../../feeds/feed_providers.dart';

/// Horizontal chip row for selecting a feed source on the search page.
///
/// Leading "All" chip selects the aggregated search across every installed
/// feed; the remaining chips pick a single source.
class FeedSelector extends ConsumerWidget {
  const FeedSelector({
    super.key,
    required this.feedState,
    required this.visibleFeeds,
    required this.selection,
  });

  final FeedListState feedState;
  final List<FeedMetaItem> visibleFeeds;
  final FeedSelection selection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    if (feedState.isLoading) {
      return const SizedBox(
        height: 48,
        child: Center(child: LanghuanSpinner(size: 20)),
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

    Widget chip({
      required String label,
      required bool selected,
      VoidCallback? onSelected,
    }) {
      return Padding(
        padding: const EdgeInsets.only(right: LanghuanTheme.spaceSm),
        child: ChoiceChip(
          label: Text(
            label,
            style: TextStyle(
              color: selected
                  ? theme.colorScheme.onPrimary
                  : theme.colorScheme.onSurface,
            ),
          ),
          selected: selected,
          onSelected: onSelected == null ? null : (_) => onSelected(),
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
        // +1 for the leading "All" chip.
        itemCount: visibleFeeds.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return chip(
              label: l10n.searchAllFeeds,
              selected: selection is FeedSelectionAll,
              onSelected: () => ref
                  .read(selectedFeedProvider.notifier)
                  .select(const FeedSelectionAll()),
            );
          }
          final feed = visibleFeeds[index - 1];
          final selectedFeedId = switch (selection) {
            FeedSelectionOne(:final feed) => feed.id,
            FeedSelectionAll() => null,
          };
          final isSelected = selectedFeedId == feed.id;
          return chip(
            label: feed.name,
            selected: isSelected,
            onSelected: () => ref
                .read(selectedFeedProvider.notifier)
                .select(FeedSelectionOne(feed)),
          );
        },
      ),
    );
  }
}

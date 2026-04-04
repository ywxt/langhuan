import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:langhuan/rust_init.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/error_state.dart';
import '../../src/bindings/signals/signals.dart';
import '../feeds/feed_providers.dart';
import 'widgets/feed_selector.dart';
import 'widgets/search_result_card.dart';

// ---------------------------------------------------------------------------
// SearchPage — Wise-inspired book search
// ---------------------------------------------------------------------------

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();

  List<FeedMetaItem> _visibleFeeds(FeedListState feedState) {
    return feedState.items
        .where((feed) => feed.error == null)
        .toList(growable: false);
  }

  FeedMetaItem? _effectiveSelectedFeed({
    required List<FeedMetaItem> visibleFeeds,
    required FeedMetaItem? selectedFeed,
  }) {
    if (visibleFeeds.isEmpty) return null;
    if (selectedFeed == null) return visibleFeeds.first;

    for (final feed in visibleFeeds) {
      if (feed.id == selectedFeed.id) {
        return feed;
      }
    }
    return visibleFeeds.first;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _searchFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onSearch() {
    final bootstrap = ref.read(appDataDirectorySetProvider);
    final bootstrapReady =
        bootstrap.asData?.value.outcome is AppDataDirectoryOutcomeSuccess;
    if (!bootstrapReady) return;

    final feedState = ref.read(feedListProvider);
    final selectedFeed = ref.read(selectedFeedProvider);
    final effectiveSelectedFeed = _effectiveSelectedFeed(
      visibleFeeds: _visibleFeeds(feedState),
      selectedFeed: selectedFeed,
    );
    if (effectiveSelectedFeed == null) return;

    final keyword = _searchController.text.trim();
    if (keyword.isEmpty) return;
    ref
        .read(searchProvider.notifier)
        .search(feedId: effectiveSelectedFeed.id, keyword: keyword);
  }

  @override
  Widget build(BuildContext context) {
    final bootstrap = ref.watch(appDataDirectorySetProvider);
    final bootstrapReady =
        bootstrap.asData?.value.outcome is AppDataDirectoryOutcomeSuccess;
    final feedState = ref.watch(feedListProvider);
    final selectedFeed = ref.watch(selectedFeedProvider);
    final visibleFeeds = _visibleFeeds(feedState);
    final effectiveSelectedFeed = _effectiveSelectedFeed(
      visibleFeeds: visibleFeeds,
      selectedFeed: selectedFeed,
    );
    final searchState = ref.watch(searchProvider);
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    if (effectiveSelectedFeed?.id != selectedFeed?.id) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (effectiveSelectedFeed == null) {
          ref.read(selectedFeedProvider.notifier).clear();
        } else {
          ref.read(selectedFeedProvider.notifier).select(effectiveSelectedFeed);
        }
      });
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.searchTitle)),
      body: Column(
        children: [
          // ── Search bar ───────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LanghuanTheme.spaceLg,
              LanghuanTheme.spaceSm,
              LanghuanTheme.spaceLg,
              LanghuanTheme.spaceSm,
            ),
            child: SearchBar(
              controller: _searchController,
              focusNode: _searchFocusNode,
              hintText: effectiveSelectedFeed == null
                  ? l10n.searchHintNoFeed
                  : l10n.searchHintWithFeed(effectiveSelectedFeed.name),
              enabled: effectiveSelectedFeed != null && bootstrapReady,
              leading: Icon(
                Icons.search,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              trailing: [
                if (searchState.isLoading)
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: l10n.searchCancel,
                    onPressed: () =>
                        ref.read(searchProvider.notifier).cancelAndClear(),
                  )
                else if (_searchController.text.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: l10n.searchClear,
                    onPressed: () {
                      _searchController.clear();
                      ref.read(searchProvider.notifier).cancelAndClear();
                    },
                  ),
              ],
              onSubmitted: (_) => _onSearch(),
            ),
          ),

          // ── Feed selector (horizontal chip row) ──────────────────────
          FeedSelector(
            feedState: feedState,
            visibleFeeds: visibleFeeds,
            selectedFeed: effectiveSelectedFeed,
          ),

          // ── Loading indicator ──────────────────────────────────────────
          if (searchState.isLoading)
            const LinearProgressIndicator()
          else
            const SizedBox(height: 2), // Reserve space
          // ── Search results ─────────────────────────────────────────────
          Expanded(
            child: _buildResults(
              context,
              searchState,
              effectiveSelectedFeed,
              l10n,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResults(
    BuildContext context,
    SearchState searchState,
    FeedMetaItem? selectedFeed,
    AppLocalizations l10n,
  ) {
    if (searchState.hasError) {
      return ErrorState(
        title: l10n.searchError,
        message: searchState.error.toString(),
        onRetry: selectedFeed == null
            ? null
            : () => ref
                  .read(searchProvider.notifier)
                  .retry(feedId: selectedFeed.id),
        retryLabel: l10n.searchRetry,
      );
    }

    if (!searchState.isLoading && !searchState.hasItems) {
      return EmptyState(
        icon: Icons.search,
        title: searchState.keyword.isEmpty
            ? l10n.searchEmptyPrompt
            : l10n.searchNoResults(searchState.keyword),
      );
    }

    // Results list — card-style items with spacing
    return ListView.builder(
      padding: const EdgeInsets.symmetric(
        horizontal: LanghuanTheme.spaceLg,
        vertical: LanghuanTheme.spaceSm,
      ),
      itemCount: searchState.items.length,
      itemBuilder: (context, index) {
        return Padding(
          padding: const EdgeInsets.only(bottom: LanghuanTheme.spaceSm),
          child: SearchResultCard(
            item: searchState.items[index],
            onTap: selectedFeed == null
                ? null
                : () {
                    final item = searchState.items[index];
                    context.pushNamed(
                      'bookshelf-book-detail',
                      queryParameters: {
                        'feedId': selectedFeed.id,
                        'bookId': item.id,
                      },
                    );
                  },
          ),
        );
      },
    );
  }
}

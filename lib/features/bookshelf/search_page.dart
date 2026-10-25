import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:langhuan/rust_init.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/error_state.dart';
import '../../shared/widgets/loading.dart';
import '../../src/rust/api/types.dart';
import '../feeds/feed_providers.dart';
import '../feeds/search_provider.dart';
import 'book_detail_page.dart';
import 'widgets/book_cover_hero.dart';
import 'widgets/feed_selector.dart';
import 'widgets/reader_types.dart';
import 'widgets/search_result_card.dart';

// ---------------------------------------------------------------------------
// SearchPage — Wise-inspired book search
// ---------------------------------------------------------------------------

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

/// One row of the results list, flattened from the per-feed groups.
sealed class _ResultRow {
  const _ResultRow();
}

class _GroupHeaderRow extends _ResultRow {
  const _GroupHeaderRow(this.group);

  final SearchFeedGroup group;
}

class _CardRow extends _ResultRow {
  const _CardRow(this.group, this.index);

  final SearchFeedGroup group;
  final int index;
}

class _GroupErrorRow extends _ResultRow {
  const _GroupErrorRow(this.group);

  final SearchFeedGroup group;
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();

  List<FeedMetaItem> _visibleFeeds(FeedListState feedState) {
    return feedState.items
        .where((feed) => feed.error == null)
        .toList(growable: false);
  }

  /// The selection in effect: a stored single-source selection survives
  /// while that feed is still installed; anything else falls back to the
  /// aggregated all-feeds search.
  FeedSelection _effectiveSelection({
    required List<FeedMetaItem> visibleFeeds,
    required FeedSelection? selected,
  }) {
    if (selected is FeedSelectionOne) {
      for (final feed in visibleFeeds) {
        if (feed.id == selected.feed.id) {
          return selected;
        }
      }
    }
    return const FeedSelectionAll();
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
        !bootstrap.isLoading &&
        !bootstrap.hasError &&
        bootstrap.asData?.value != null;
    if (!bootstrapReady) return;

    final feedState = ref.read(feedListProvider);
    final visibleFeeds = _visibleFeeds(feedState);
    if (visibleFeeds.isEmpty) return;

    final selection = _effectiveSelection(
      visibleFeeds: visibleFeeds,
      selected: ref.read(selectedFeedProvider),
    );

    final keyword = _searchController.text.trim();
    if (keyword.isEmpty) return;

    switch (selection) {
      case FeedSelectionOne(:final feed):
        ref
            .read(searchProvider.notifier)
            .search(feedId: feed.id, feedName: feed.name, keyword: keyword);
      case FeedSelectionAll():
        ref.read(searchProvider.notifier).searchAll(keyword: keyword);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bootstrap = ref.watch(appDataDirectorySetProvider);
    final bootstrapReady =
        !bootstrap.isLoading &&
        !bootstrap.hasError &&
        bootstrap.asData?.value != null;
    final feedState = ref.watch(feedListProvider);
    final selected = ref.watch(selectedFeedProvider);
    final visibleFeeds = _visibleFeeds(feedState);
    final effectiveSelection = _effectiveSelection(
      visibleFeeds: visibleFeeds,
      selected: selected,
    );
    final searchState = ref.watch(searchProvider);
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    // Coerce a stale selection (feed removed, or nothing chosen yet) into
    // the effective one.
    if (selected != effectiveSelection) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(selectedFeedProvider.notifier).select(effectiveSelection);
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
              hintText: switch (effectiveSelection) {
                FeedSelectionOne(:final feed) => l10n.searchHintWithFeed(
                  feed.name,
                ),
                FeedSelectionAll() =>
                  visibleFeeds.isEmpty
                      ? l10n.searchHintNoFeed
                      : l10n.searchHintAllFeeds,
              },
              enabled: visibleFeeds.isNotEmpty && bootstrapReady,
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
            selection: effectiveSelection,
          ),

          // ── Loading indicator ──────────────────────────────────────────
          if (searchState.isLoading)
            const LinearProgressIndicator(minHeight: 2)
          else
            const SizedBox(height: 2), // Reserve space
          // ── Search results ─────────────────────────────────────────────
          Expanded(
            child: _buildResults(
              context,
              searchState,
              effectiveSelection,
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
    FeedSelection selection,
    AppLocalizations l10n,
  ) {
    if (searchState.hasError) {
      final showAuth =
          selection is FeedSelectionOne &&
          isAuthRequiredError(searchState.error);

      return Column(
        children: [
          Expanded(
            child: ErrorState(
              title: l10n.searchError,
              message: normalizeErrorMessage(searchState.error!),
              onRetry: () => ref.read(searchProvider.notifier).retry(),
              retryLabel: l10n.searchRetry,
            ),
          ),
          if (showAuth)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                LanghuanTheme.spaceLg,
                0,
                LanghuanTheme.spaceLg,
                LanghuanTheme.spaceLg,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.searchAuthHint,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  const SizedBox(width: LanghuanTheme.spaceSm),
                  FilledButton.icon(
                    onPressed: () async {
                      final loggedIn = await context.pushNamed<bool>(
                        'feed-auth',
                        queryParameters: {'feedId': selection.feed.id},
                      );
                      if (loggedIn == true && context.mounted) {
                        ref.read(searchProvider.notifier).retry();
                      }
                    },
                    icon: const Icon(Icons.login),
                    label: Text(l10n.searchAuthAction),
                  ),
                ],
              ),
            ),
        ],
      );
    }

    final allGroupsHealthy = searchState.groups.every(
      (group) => group.error == null,
    );
    if (!searchState.isLoading && !searchState.hasItems && allGroupsHealthy) {
      return EmptyState(
        icon: Icons.search,
        title: searchState.keyword.isEmpty
            ? l10n.searchEmptyPrompt
            : l10n.searchNoResults(searchState.keyword),
      );
    }

    // Flatten the per-feed groups into rows. Headers only appear when more
    // than one source contributed, so a single-source search keeps its
    // flat layout.
    final showHeaders = searchState.groups.length > 1;
    final rows = <_ResultRow>[];
    for (final group in searchState.groups) {
      if (showHeaders) {
        rows.add(_GroupHeaderRow(group));
      }
      for (var i = 0; i < group.items.length; i++) {
        rows.add(_CardRow(group, i));
      }
      if (group.error != null) {
        rows.add(_GroupErrorRow(group));
      }
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification &&
            notification.metrics.extentAfter < 200 &&
            !searchState.isLoadingMore &&
            searchState.hasMore) {
          ref.read(searchProvider.notifier).loadMore();
        }
        return false;
      },
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(
          horizontal: LanghuanTheme.spaceLg,
          vertical: LanghuanTheme.spaceSm,
        ),
        itemCount: rows.length + (searchState.hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= rows.length) {
            // Loading indicator at the bottom
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: LanghuanTheme.spaceLg),
              child: Center(child: LanghuanSpinner()),
            );
          }
          return Padding(
            padding: const EdgeInsets.only(bottom: LanghuanTheme.spaceSm),
            child: switch (rows[index]) {
              _GroupHeaderRow(:final group) => _buildGroupHeader(
                context,
                group,
              ),
              _CardRow(:final group, :final index) => _buildResultCard(
                context,
                group: group,
                index: index,
              ),
              _GroupErrorRow(:final group) => _buildGroupError(
                context,
                group,
                l10n,
              ),
            },
          );
        },
      ),
    );
  }

  Widget _buildGroupHeader(BuildContext context, SearchFeedGroup group) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(
        top: LanghuanTheme.spaceMd,
        bottom: LanghuanTheme.spaceSm,
      ),
      child: Text(
        group.feedName,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildResultCard(
    BuildContext context, {
    required SearchFeedGroup group,
    required int index,
  }) {
    final item = group.items[index];
    return SearchResultCard(
      item: item,
      coverHeroTag: bookCoverHeroTag(group.feedId, item.id),
      titleHeroTag: bookTitleHeroTag(group.feedId, item.id),
      authorHeroTag: bookAuthorHeroTag(group.feedId, item.id),
      onTap: () {
        context.pushNamed(
          'bookshelf-book-detail',
          queryParameters: {'feedId': group.feedId, 'bookId': item.id},
          extra: BookDetailRouteExtra(
            coverUrl: item.coverUrl,
            title: item.title,
            author: item.author,
          ),
        );
      },
    );
  }

  Widget _buildGroupError(
    BuildContext context,
    SearchFeedGroup group,
    AppLocalizations l10n,
  ) {
    final theme = Theme.of(context);
    final error = group.error;
    if (error == null) {
      return const SizedBox.shrink();
    }
    final showAuth = isAuthRequiredError(error);

    return Material(
      color: theme.colorScheme.surfaceContainer,
      borderRadius: LanghuanTheme.borderRadiusMd,
      child: Padding(
        padding: const EdgeInsets.all(LanghuanTheme.spaceMd),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: theme.colorScheme.error, size: 20),
            const SizedBox(width: LanghuanTheme.spaceMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.searchSourceFailed(group.feedName),
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: LanghuanTheme.spaceXs),
                  Text(
                    normalizeErrorMessage(error),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (showAuth) ...[
              const SizedBox(width: LanghuanTheme.spaceSm),
              FilledButton.tonalIcon(
                onPressed: () async {
                  final loggedIn = await context.pushNamed<bool>(
                    'feed-auth',
                    queryParameters: {'feedId': group.feedId},
                  );
                  if (loggedIn == true && context.mounted) {
                    ref.read(searchProvider.notifier).retry();
                  }
                },
                icon: const Icon(Icons.login),
                label: Text(l10n.searchAuthAction),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

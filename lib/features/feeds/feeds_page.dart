import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'feed_providers.dart';
import 'feed_service.dart';

// ---------------------------------------------------------------------------
// TODO: Replace this with your actual feed ID loaded from storage.
// ---------------------------------------------------------------------------
const _demoFeedId = 'path/to/your/feed_script.lua';

class FeedsPage extends ConsumerStatefulWidget {
  const FeedsPage({super.key});

  @override
  ConsumerState<FeedsPage> createState() => _FeedsPageState();
}

class _FeedsPageState extends ConsumerState<FeedsPage> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onSearch() {
    final keyword = _searchController.text.trim();
    if (keyword.isEmpty) return;
    ref.read(searchProvider.notifier).search(
          feedId: _demoFeedId,
          keyword: keyword,
        );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(searchProvider);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // ── App bar ─────────────────────────────────────────────────────
          SliverAppBar.medium(
            title: const Text('Feeds'),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(72),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: SearchBar(
                  controller: _searchController,
                  hintText: 'Search books…',
                  leading: const Icon(Icons.search),
                  trailing: [
                    if (state.isLoading)
                      IconButton(
                        icon: const Icon(Icons.cancel_outlined),
                        tooltip: 'Cancel',
                        onPressed: () =>
                            ref.read(searchProvider.notifier).cancelAndClear(),
                      )
                    else if (_searchController.text.isNotEmpty)
                      IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          ref.read(searchProvider.notifier).cancelAndClear();
                        },
                      ),
                  ],
                  onSubmitted: (_) => _onSearch(),
                ),
              ),
            ),
          ),

          // ── Loading indicator ────────────────────────────────────────────
          if (state.isLoading)
            const SliverToBoxAdapter(
              child: LinearProgressIndicator(),
            ),

          // ── Error banner ─────────────────────────────────────────────────
          if (state.hasError)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Card(
                  color: colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Something went wrong',
                          style: TextStyle(
                            color: colorScheme.onErrorContainer,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          state.error.toString(),
                          style: TextStyle(color: colorScheme.onErrorContainer),
                        ),
                        const SizedBox(height: 8),
                        FilledButton.tonal(
                          onPressed: () => ref
                              .read(searchProvider.notifier)
                              .retry(feedId: _demoFeedId),
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // ── Empty state ──────────────────────────────────────────────────
          if (!state.isLoading && !state.hasError && !state.hasItems)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.rss_feed,
                        size: 64,
                        color: colorScheme.onSurfaceVariant.withAlpha(100)),
                    const SizedBox(height: 16),
                    Text(
                      state.keyword.isEmpty
                          ? 'Search for books above'
                          : 'No results for "${state.keyword}"',
                      style: TextStyle(color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),

          // ── Results list ─────────────────────────────────────────────────
          SliverList.builder(
            itemCount: state.items.length,
            itemBuilder: (context, index) {
              final item = state.items[index];
              return _SearchResultTile(item: item);
            },
          ),

          // ── Streaming badge at bottom ─────────────────────────────────
          if (state.isLoading && state.hasItems)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Loading more…',
                      style: TextStyle(color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Search result tile
// ---------------------------------------------------------------------------

class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({required this.item});

  final SearchResultModel item;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: item.coverUrl != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.network(
                item.coverUrl!,
                width: 40,
                height: 56,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    const Icon(Icons.menu_book, size: 40),
              ),
            )
          : const Icon(Icons.menu_book, size: 40),
      title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${item.author}${item.description != null ? '\n${item.description}' : ''}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: item.description != null,
      onTap: () {
        // TODO: navigate to book detail page
      },
    );
  }
}


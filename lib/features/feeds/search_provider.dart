import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'feed_providers.dart';
import 'feed_service.dart';

// ---------------------------------------------------------------------------
// Search state
// ---------------------------------------------------------------------------

const _pageSize = 20;

/// Results from one source. An aggregated search holds one group per feed
/// that produced results or an error; a single-source search holds exactly
/// one.
class SearchFeedGroup {
  const SearchFeedGroup({
    required this.feedId,
    required this.feedName,
    this.items = const [],
    this.error,
  });

  final String feedId;
  final String feedName;
  final List<SearchResultModel> items;
  final String? error;

  SearchFeedGroup copyWith({
    List<SearchResultModel>? items,
    String? Function()? error,
  }) {
    return SearchFeedGroup(
      feedId: feedId,
      feedName: feedName,
      items: items ?? this.items,
      error: error != null ? error() : this.error,
    );
  }
}

class SearchState {
  const SearchState({
    this.keyword = '',
    this.groups = const [],
    this.isLoading = false,
    this.isLoadingMore = false,
    this.hasMore = true,
    this.error,
  });

  final String keyword;
  final List<SearchFeedGroup> groups;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;
  final Object? error;

  bool get hasError => error != null;
  bool get hasItems => groups.any((group) => group.items.isNotEmpty);
  bool get isIdle => !isLoading && !isLoadingMore && !hasError;

  SearchState copyWith({
    String? keyword,
    List<SearchFeedGroup>? groups,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
    Object? Function()? error,
  }) {
    return SearchState(
      keyword: keyword ?? this.keyword,
      groups: groups ?? this.groups,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      error: error != null ? error() : this.error,
    );
  }
}

class SearchNotifier extends Notifier<SearchState> {
  int _runToken = 0;
  StreamIterator<AggregatedSearchEventModel>? _iterator;

  /// The single feed of the last search, or null when it was an
  /// all-feeds search. Kept for [retry].
  String? _lastFeedId;
  String? _lastFeedName;

  @override
  SearchState build() => const SearchState();

  Future<void> search({
    required String feedId,
    required String feedName,
    required String keyword,
  }) async {
    _lastFeedId = feedId;
    _lastFeedName = feedName;
    await _run(
      keyword: keyword,
      stream: ref
          .read(feedServiceProvider)
          .search(feedId: feedId, keyword: keyword)
          .map(
            (item) => AggregatedSearchEventModel(
              feedId: feedId,
              feedName: feedName,
              item: item,
            ),
          ),
    );
  }

  Future<void> searchAll({required String keyword}) async {
    _lastFeedId = null;
    _lastFeedName = null;
    await _run(
      keyword: keyword,
      stream: ref.read(feedServiceProvider).searchAll(keyword: keyword),
    );
  }

  Future<void> retry() async {
    if (state.keyword.isEmpty) return;
    if (_lastFeedId case final feedId?) {
      await search(
        feedId: feedId,
        feedName: _lastFeedName ?? feedId,
        keyword: state.keyword,
      );
    } else {
      await searchAll(keyword: state.keyword);
    }
  }

  Future<void> loadMore() async {
    if (state.isLoading || state.isLoadingMore || !state.hasMore) return;
    if (_iterator == null) return;

    final runToken = _runToken;
    state = state.copyWith(isLoadingMore: true);
    await _loadPage(runToken: runToken);
  }

  Future<void> cancelAndClear() async {
    _runToken++;
    _disposeIterator();
    state = const SearchState();
  }

  Future<void> _run({
    required String keyword,
    required Stream<AggregatedSearchEventModel> stream,
  }) async {
    _runToken++;
    final runToken = _runToken;
    _disposeIterator();

    state = SearchState(keyword: keyword, isLoading: true);

    _iterator = StreamIterator(stream);
    await _loadPage(runToken: runToken);
  }

  /// Pull up to [_pageSize] events and route them into per-feed groups.
  /// Feed errors land in their group instead of failing the whole run.
  Future<void> _loadPage({required int runToken}) async {
    try {
      final groups = <String, SearchFeedGroup>{};
      for (final group in state.groups) {
        groups[group.feedId] = group.copyWith(
          items: List.of(group.items),
        );
      }
      var exhausted = false;

      for (var i = 0; i < _pageSize; i++) {
        final hasNext = await _iterator!.moveNext();
        if (runToken != _runToken) return;
        if (!hasNext) {
          exhausted = true;
          break;
        }

        final event = _iterator!.current;
        final existing = groups[event.feedId];
        if (event.error != null) {
          groups[event.feedId] = SearchFeedGroup(
            feedId: event.feedId,
            feedName: event.feedName,
            items: existing?.items ?? const [],
            error: event.error,
          );
        } else {
          final item = event.item!;
          groups[event.feedId] = SearchFeedGroup(
            feedId: event.feedId,
            feedName: event.feedName,
            items: [...existing?.items ?? const [], item],
            error: existing?.error,
          );
        }
      }

      state = state.copyWith(
        groups: List.unmodifiable(groups.values),
        isLoading: false,
        isLoadingMore: false,
        hasMore: !exhausted,
      );
    } catch (err) {
      if (runToken == _runToken) {
        state = state.copyWith(
          isLoading: false,
          isLoadingMore: false,
          hasMore: false,
          error: () => err,
        );
      }
    }
  }

  void _disposeIterator() {
    _iterator?.cancel();
    _iterator = null;
  }
}

final searchProvider = NotifierProvider<SearchNotifier, SearchState>(
  SearchNotifier.new,
);

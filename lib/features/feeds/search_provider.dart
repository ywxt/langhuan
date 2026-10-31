import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'feed_providers.dart';
import 'feed_service.dart';

// ---------------------------------------------------------------------------
// Search state
// ---------------------------------------------------------------------------

const _pageSize = 20;
const _resultWindow = Duration(milliseconds: 40);

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
  Future<bool>? _pendingMoveNext;

  /// The single feed of the last search, or null when it was an
  /// all-feeds search. Kept for [retry].
  String? _lastFeedId;
  String? _lastFeedName;

  @override
  SearchState build() {
    ref.onDispose(() {
      _runToken++;
      _disposeIterator();
    });
    return const SearchState();
  }

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
            (items) => [
              for (final item in items)
                AggregatedSearchEventModel(
                  feedId: feedId,
                  feedName: feedName,
                  item: item,
                ),
            ],
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
    required Stream<List<AggregatedSearchEventModel>> stream,
  }) async {
    _runToken++;
    final runToken = _runToken;
    _disposeIterator();

    state = SearchState(keyword: keyword, isLoading: true);

    // Buffer bridge batches locally; UI pagination never crosses the bridge
    // once per item, and does not discard an oversized/partially used batch.
    _iterator = StreamIterator(stream.expand((batch) => batch));
    await _loadPage(runToken: runToken);
  }

  /// Pull up to [_pageSize] events and route them into per-feed groups.
  /// Feed errors land in their group instead of failing the whole run.
  Future<void> _loadPage({
    required int runToken,
    int budget = _pageSize,
  }) async {
    final groups = <String, SearchFeedGroup>{};
    for (final group in state.groups) {
      groups[group.feedId] = group.copyWith(items: List.of(group.items));
    }
    try {
      final seenIds = <String, Set<String>>{
        for (final group in groups.values)
          group.feedId: group.items.map((item) => item.id).toSet(),
      };
      var exhausted = false;
      var consumed = 0;
      final window = Stopwatch();
      final iterator = _iterator!;

      for (var i = 0; i < budget; i++) {
        final remaining = _resultWindow - window.elapsed;
        if (window.isRunning && remaining <= Duration.zero) break;
        // StreamIterator.moveNext cannot be cancelled by a timeout. Retain
        // that exact future so the next load resumes it without skipping an
        // event or issuing a second concurrent moveNext.
        final pending = _pendingMoveNext ??= iterator.moveNext();
        final hasNext = window.isRunning
            ? await pending
                  .then<bool?>((value) => value)
                  .timeout(remaining, onTimeout: () => null)
            : await pending;
        if (runToken != _runToken) return;
        if (hasNext == null) break;
        _pendingMoveNext = null;
        if (!hasNext) {
          exhausted = true;
          break;
        }
        if (!window.isRunning) window.start();
        consumed++;

        final event = iterator.current;
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
          final ids = seenIds.putIfAbsent(event.feedId, () => <String>{});
          // The native runtime already removes overlapping search pages.
          // Keep the UI boundary defensive as well so route restoration can
          // never create duplicate Hero identities from another service.
          if (!ids.add(item.id)) continue;
          groups[event.feedId] = SearchFeedGroup(
            feedId: event.feedId,
            feedName: event.feedName,
            items: [...existing?.items ?? const [], item],
            error: existing?.error,
          );
        }
      }

      if (runToken != _runToken) return;
      final continuePage = !exhausted && consumed < budget;
      state = state.copyWith(
        groups: List.unmodifiable(groups.values),
        isLoading: false,
        isLoadingMore: continuePage,
        hasMore: !exhausted,
      );
      // Keep filling this same UI page after publishing a partial result.
      // Otherwise a short list might not be scrollable, leaving slow-source
      // results inaccessible until a gesture artificially triggers loadMore.
      if (continuePage) {
        unawaited(_loadPage(runToken: runToken, budget: budget - consumed));
      }
    } catch (err) {
      if (runToken == _runToken) {
        state = state.copyWith(
          groups: List.unmodifiable(groups.values),
          isLoading: false,
          isLoadingMore: false,
          hasMore: false,
          error: () => err,
        );
      }
    }
  }

  void _disposeIterator() {
    _pendingMoveNext = null;
    _iterator?.cancel();
    _iterator = null;
  }
}

final searchProvider =
    NotifierProvider.autoDispose<SearchNotifier, SearchState>(
      SearchNotifier.new,
    );

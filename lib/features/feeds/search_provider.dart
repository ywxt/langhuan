import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'feed_service.dart';

// ---------------------------------------------------------------------------
// Search state
// ---------------------------------------------------------------------------

const _pageSize = 20;

class SearchState {
  const SearchState({
    this.keyword = '',
    this.items = const [],
    this.isLoading = false,
    this.isLoadingMore = false,
    this.hasMore = true,
    this.error,
  });

  final String keyword;
  final List<SearchResultModel> items;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;
  final Object? error;

  bool get hasError => error != null;
  bool get hasItems => items.isNotEmpty;
  bool get isIdle => !isLoading && !isLoadingMore && !hasError;

  SearchState copyWith({
    String? keyword,
    List<SearchResultModel>? items,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
    Object? Function()? error,
  }) {
    return SearchState(
      keyword: keyword ?? this.keyword,
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      error: error != null ? error() : this.error,
    );
  }
}

class SearchNotifier extends Notifier<SearchState> {
  int _runToken = 0;
  StreamIterator<SearchResultModel>? _iterator;

  @override
  SearchState build() => const SearchState();

  Future<void> search({required String feedId, required String keyword}) async {
    _runToken++;
    final runToken = _runToken;
    _disposeIterator();

    state = SearchState(keyword: keyword, isLoading: true);

    final stream = FeedService.instance.search(
      feedId: feedId,
      keyword: keyword,
    );
    _iterator = StreamIterator(stream);

    await _loadPage(runToken: runToken, initial: true);
  }

  Future<void> loadMore() async {
    if (state.isLoading || state.isLoadingMore || !state.hasMore) return;
    if (_iterator == null) return;

    final runToken = _runToken;
    state = state.copyWith(isLoadingMore: true);
    await _loadPage(runToken: runToken, initial: false);
  }

  Future<void> cancelAndClear() async {
    _runToken++;
    _disposeIterator();
    state = const SearchState();
  }

  Future<void> retry({required String feedId}) async {
    if (state.keyword.isEmpty) return;
    await search(feedId: feedId, keyword: state.keyword);
  }

  Future<void> _loadPage({required int runToken, required bool initial}) async {
    try {
      final items = List<SearchResultModel>.of(state.items);
      var exhausted = false;

      for (var i = 0; i < _pageSize; i++) {
        final hasNext = await _iterator!.moveNext();
        if (runToken != _runToken) return;
        if (!hasNext) {
          exhausted = true;
          break;
        }
        items.add(_iterator!.current);
      }

      state = state.copyWith(
        items: List.unmodifiable(items),
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

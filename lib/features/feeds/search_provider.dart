import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'feed_service.dart';

// ---------------------------------------------------------------------------
// Search state
// ---------------------------------------------------------------------------

class SearchState {
  const SearchState({
    this.keyword = '',
    this.items = const [],
    this.isLoading = false,
    this.error,
    this.requestId,
  });

  final String keyword;
  final List<SearchResultModel> items;
  final bool isLoading;
  final Object? error;

  /// Non-null while a stream request is in flight.
  final String? requestId;

  bool get hasError => error != null;
  bool get hasItems => items.isNotEmpty;
  bool get isIdle => !isLoading && !hasError;

  SearchState copyWith({
    String? keyword,
    List<SearchResultModel>? items,
    bool? isLoading,
    Object? Function()? error,
    String? Function()? requestId,
  }) {
    return SearchState(
      keyword: keyword ?? this.keyword,
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
      error: error != null ? error() : this.error,
      requestId: requestId != null ? requestId() : this.requestId,
    );
  }
}

class SearchNotifier extends Notifier<SearchState> {
  StreamSubscription<SearchResultModel>? _subscription;

  @override
  SearchState build() => const SearchState();

  Future<void> search({required String feedId, required String keyword}) async {
    await _cancelCurrent();

    state = SearchState(keyword: keyword, isLoading: true);

    final (:requestId, :stream) = FeedService.instance.search(
      feedId: feedId,
      keyword: keyword,
    );

    state = state.copyWith(requestId: () => requestId);

    _subscription = stream.listen(
      (item) {
        state = state.copyWith(items: [...state.items, item]);
      },
      onError: (Object err) {
        state = state.copyWith(
          isLoading: false,
          error: () => err,
          requestId: () => null,
        );
      },
      onDone: () {
        state = state.copyWith(isLoading: false, requestId: () => null);
      },
    );
  }

  Future<void> cancelAndClear() async {
    await _cancelCurrent();
    state = const SearchState();
  }

  Future<void> retry({required String feedId}) async {
    if (state.keyword.isEmpty) return;
    await search(feedId: feedId, keyword: state.keyword);
  }

  Future<void> _cancelCurrent() async {
    final id = state.requestId;
    if (id != null) {
      FeedService.instance.cancel(id);
    }
    await _subscription?.cancel();
    _subscription = null;
  }
}

final searchProvider = NotifierProvider<SearchNotifier, SearchState>(
  SearchNotifier.new,
);

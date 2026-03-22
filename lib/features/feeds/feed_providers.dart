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

// ---------------------------------------------------------------------------
// SearchNotifier
// ---------------------------------------------------------------------------

class SearchNotifier extends Notifier<SearchState> {
  StreamSubscription<SearchResultModel>? _subscription;

  @override
  SearchState build() => const SearchState();

  /// Start a new search.  Cancels any previous in-flight request.
  Future<void> search({required String feedId, required String keyword}) async {
    // Cancel previous request first.
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

  /// Cancel the current in-flight request and clear results.
  Future<void> cancelAndClear() async {
    await _cancelCurrent();
    state = const SearchState();
  }

  /// Retry the last search (reuse the same keyword).
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

// ---------------------------------------------------------------------------
// Chapters state
// ---------------------------------------------------------------------------

class ChaptersState {
  const ChaptersState({
    this.bookId = '',
    this.items = const [],
    this.isLoading = false,
    this.error,
    this.requestId,
  });

  final String bookId;
  final List<ChapterInfoModel> items;
  final bool isLoading;
  final Object? error;
  final String? requestId;

  bool get hasError => error != null;

  ChaptersState copyWith({
    String? bookId,
    List<ChapterInfoModel>? items,
    bool? isLoading,
    Object? Function()? error,
    String? Function()? requestId,
  }) {
    return ChaptersState(
      bookId: bookId ?? this.bookId,
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
      error: error != null ? error() : this.error,
      requestId: requestId != null ? requestId() : this.requestId,
    );
  }
}

class ChaptersNotifier extends Notifier<ChaptersState> {
  StreamSubscription<ChapterInfoModel>? _subscription;

  @override
  ChaptersState build() => const ChaptersState();

  Future<void> load({required String feedId, required String bookId}) async {
    await _cancelCurrent();

    state = ChaptersState(bookId: bookId, isLoading: true);

    final (:requestId, :stream) = FeedService.instance.chapters(
      feedId: feedId,
      bookId: bookId,
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

  Future<void> cancel() async => _cancelCurrent();

  Future<void> retry({required String feedId}) async {
    if (state.bookId.isEmpty) return;
    await load(feedId: feedId, bookId: state.bookId);
  }

  Future<void> _cancelCurrent() async {
    final id = state.requestId;
    if (id != null) FeedService.instance.cancel(id);
    await _subscription?.cancel();
    _subscription = null;
  }
}

// ---------------------------------------------------------------------------
// Chapter content state
// ---------------------------------------------------------------------------

class ChapterContentState {
  const ChapterContentState({
    this.chapterId = '',
    this.items = const [],
    this.isLoading = false,
    this.error,
    this.requestId,
  });

  final String chapterId;
  final List<ChapterContentModel> items;
  final bool isLoading;
  final Object? error;
  final String? requestId;

  bool get hasError => error != null;
  List<String> get allParagraphs =>
      items.expand((c) => c.paragraphs).toList(growable: false);

  ChapterContentState copyWith({
    String? chapterId,
    List<ChapterContentModel>? items,
    bool? isLoading,
    Object? Function()? error,
    String? Function()? requestId,
  }) {
    return ChapterContentState(
      chapterId: chapterId ?? this.chapterId,
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
      error: error != null ? error() : this.error,
      requestId: requestId != null ? requestId() : this.requestId,
    );
  }
}

class ChapterContentNotifier extends Notifier<ChapterContentState> {
  StreamSubscription<ChapterContentModel>? _subscription;

  @override
  ChapterContentState build() => const ChapterContentState();

  Future<void> load({required String feedId, required String chapterId}) async {
    await _cancelCurrent();

    state = ChapterContentState(chapterId: chapterId, isLoading: true);

    final (:requestId, :stream) = FeedService.instance.chapterContent(
      feedId: feedId,
      chapterId: chapterId,
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

  Future<void> cancel() async => _cancelCurrent();

  Future<void> retry({required String feedId}) async {
    if (state.chapterId.isEmpty) return;
    await load(feedId: feedId, chapterId: state.chapterId);
  }

  Future<void> _cancelCurrent() async {
    final id = state.requestId;
    if (id != null) FeedService.instance.cancel(id);
    await _subscription?.cancel();
    _subscription = null;
  }
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

final searchProvider = NotifierProvider<SearchNotifier, SearchState>(
  SearchNotifier.new,
);

final chaptersProvider = NotifierProvider<ChaptersNotifier, ChaptersState>(
  ChaptersNotifier.new,
);

final chapterContentProvider =
    NotifierProvider<ChapterContentNotifier, ChapterContentState>(
      ChapterContentNotifier.new,
    );

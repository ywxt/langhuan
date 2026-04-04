import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust_init.dart';
import '../../src/bindings/signals/signals.dart';
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
// Book info state
// ---------------------------------------------------------------------------

class BookInfoState {
  const BookInfoState({
    this.feedId = '',
    this.bookId = '',
    this.book,
    this.isLoading = false,
    this.error,
  });

  final String feedId;
  final String bookId;
  final BookInfoModel? book;
  final bool isLoading;
  final Object? error;

  bool get hasError => error != null;

  BookInfoState copyWith({
    String? feedId,
    String? bookId,
    BookInfoModel? Function()? book,
    bool? isLoading,
    Object? Function()? error,
  }) {
    return BookInfoState(
      feedId: feedId ?? this.feedId,
      bookId: bookId ?? this.bookId,
      book: book != null ? book() : this.book,
      isLoading: isLoading ?? this.isLoading,
      error: error != null ? error() : this.error,
    );
  }
}

class BookInfoNotifier extends Notifier<BookInfoState> {
  @override
  BookInfoState build() => const BookInfoState();

  Future<void> load({required String feedId, required String bookId}) async {
    state = BookInfoState(feedId: feedId, bookId: bookId, isLoading: true);

    try {
      final book = await FeedService.instance.bookInfo(
        feedId: feedId,
        bookId: bookId,
      );
      state = state.copyWith(
        book: () => book,
        isLoading: false,
        error: () => null,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: () => e,
        book: () => null,
      );
    }
  }

  Future<void> retry() async {
    if (state.feedId.isEmpty || state.bookId.isEmpty) return;
    await load(feedId: state.feedId, bookId: state.bookId);
  }

  void clear() => state = const BookInfoState();
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
  final List<ParagraphContent> items;
  final bool isLoading;
  final Object? error;
  final String? requestId;

  bool get hasError => error != null;
  List<String> get allParagraphs => items
      .whereType<ParagraphContentText>()
      .map((p) => p.content)
      .toList(growable: false);

  ChapterContentState copyWith({
    String? chapterId,
    List<ParagraphContent>? items,
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
  StreamSubscription<ParagraphContent>? _subscription;

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
// Feed list state
// ---------------------------------------------------------------------------

class FeedListState {
  const FeedListState({
    this.items = const [],
    this.isLoading = false,
    this.error,
    this.removingFeedId,
  });

  final List<FeedMetaItem> items;
  final bool isLoading;
  final Object? error;
  final String? removingFeedId;

  bool get hasError => error != null;
  bool get hasItems => items.isNotEmpty;
  bool get isRemoving => removingFeedId != null;

  FeedListState copyWith({
    List<FeedMetaItem>? items,
    bool? isLoading,
    Object? Function()? error,
    String? Function()? removingFeedId,
  }) {
    return FeedListState(
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
      error: error != null ? error() : this.error,
      removingFeedId: removingFeedId != null
          ? removingFeedId()
          : this.removingFeedId,
    );
  }
}

class FeedListNotifier extends Notifier<FeedListState> {
  bool _requestedInitialLoad = false;

  @override
  FeedListState build() {
    final bootstrap = ref.watch(appDataDirectorySetProvider);

    if (bootstrap.isLoading) {
      return const FeedListState(isLoading: true);
    }

    if (bootstrap.hasError) {
      return FeedListState(error: bootstrap.error);
    }

    final result = bootstrap.asData?.value;
    if (result == null) {
      return const FeedListState();
    }

    final outcome = result.outcome;
    if (outcome is AppDataDirectoryOutcomeError) {
      return FeedListState(error: outcome.message);
    }

    if (!_requestedInitialLoad) {
      _requestedInitialLoad = true;
      Future.microtask(load);
    }

    return const FeedListState();
  }

  Future<void> load() async {
    final bootstrap = ref.read(appDataDirectorySetProvider);
    final result = bootstrap.asData?.value;

    if (bootstrap.isLoading) {
      state = const FeedListState(isLoading: true);
      return;
    }

    if (bootstrap.hasError) {
      state = FeedListState(error: bootstrap.error);
      return;
    }

    if (result == null || result.outcome is AppDataDirectoryOutcomeError) {
      final outcome = result?.outcome;
      final message = outcome is AppDataDirectoryOutcomeError
          ? outcome.message
          : 'app data directory not ready';
      state = FeedListState(error: message);
      return;
    }

    state = const FeedListState(isLoading: true);
    try {
      final result = await FeedService.instance.listFeeds();
      state = FeedListState(items: List.unmodifiable(result.items));
    } catch (e) {
      state = FeedListState(error: e);
    }
  }

  /// Remove one feed, refresh list, and clear selected feed if needed.
  ///
  /// Returns `null` on success, or a user-facing error message on failure.
  Future<String?> removeFeed({required String feedId}) async {
    if (state.isRemoving) return 'busy';

    state = state.copyWith(removingFeedId: () => feedId, error: () => null);

    try {
      final result = await FeedService.instance.removeFeed(feedId);
      final outcome = result.outcome;
      if (outcome is FeedRemoveOutcomeError) {
        return outcome.message;
      }

      final selected = ref.read(selectedFeedProvider);
      if (selected?.id == feedId) {
        ref.read(selectedFeedProvider.notifier).clear();
      }

      // Remove immediately for Dismissible, then sync from Rust.
      final nextItems = state.items
          .where((item) => item.id != feedId)
          .toList(growable: false);
      state = state.copyWith(items: nextItems, removingFeedId: () => null);

      await load();
      return null;
    } catch (e) {
      return e.toString();
    } finally {
      if (state.removingFeedId == feedId) {
        state = state.copyWith(removingFeedId: () => null);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Bookshelf state
// ---------------------------------------------------------------------------

class BookshelfState {
  const BookshelfState({
    this.items = const [],
    this.isLoading = false,
    this.error,
    this.activeItemId,
  });

  final List<BookshelfItemModel> items;
  final bool isLoading;
  final Object? error;
  final String? activeItemId;

  bool get hasError => error != null;

  bool contains({required String feedId, required String sourceBookId}) {
    return items.any(
      (item) => item.feedId == feedId && item.sourceBookId == sourceBookId,
    );
  }

  BookshelfState copyWith({
    List<BookshelfItemModel>? items,
    bool? isLoading,
    Object? Function()? error,
    String? Function()? activeItemId,
  }) {
    return BookshelfState(
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
      error: error != null ? error() : this.error,
      activeItemId: activeItemId != null ? activeItemId() : this.activeItemId,
    );
  }
}

class BookshelfNotifier extends Notifier<BookshelfState> {
  bool _initialized = false;

  @override
  BookshelfState build() {
    if (!_initialized) {
      _initialized = true;
      Future.microtask(load);
    }
    return const BookshelfState(isLoading: true);
  }

  Future<void> load() async {
    state = state.copyWith(isLoading: true, error: () => null);
    try {
      final items = await FeedService.instance.listBookshelf();
      state = state.copyWith(items: items, isLoading: false, error: () => null);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: () => e);
    }
  }

  Future<BookshelfOperationOutcome> add({
    required String feedId,
    required BookInfoModel book,
  }) async {
    final itemId = '$feedId:${book.id}';
    state = state.copyWith(activeItemId: () => itemId, error: () => null);

    try {
      final outcome = await FeedService.instance.addToBookshelf(
        feedId: feedId,
        sourceBookId: book.id,
        title: book.title,
        author: book.author,
        coverUrl: book.coverUrl,
        descriptionSnapshot: book.description,
      );
      await load();
      return outcome;
    } finally {
      if (state.activeItemId == itemId) {
        state = state.copyWith(activeItemId: () => null);
      }
    }
  }

  Future<BookshelfOperationOutcome> remove({
    required String feedId,
    required String sourceBookId,
  }) async {
    final itemId = '$feedId:$sourceBookId';
    state = state.copyWith(activeItemId: () => itemId, error: () => null);

    try {
      final outcome = await FeedService.instance.removeFromBookshelf(
        feedId: feedId,
        sourceBookId: sourceBookId,
      );
      await load();
      return outcome;
    } finally {
      if (state.activeItemId == itemId) {
        state = state.copyWith(activeItemId: () => null);
      }
    }
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

final bookInfoProvider = NotifierProvider<BookInfoNotifier, BookInfoState>(
  BookInfoNotifier.new,
);

final chapterContentProvider =
    NotifierProvider<ChapterContentNotifier, ChapterContentState>(
      ChapterContentNotifier.new,
    );

final feedListProvider = NotifierProvider<FeedListNotifier, FeedListState>(
  FeedListNotifier.new,
);

final bookshelfProvider = NotifierProvider<BookshelfNotifier, BookshelfState>(
  BookshelfNotifier.new,
);

final bookshelfCapabilitiesProvider =
    FutureProvider.family<BookshelfCapabilitiesModel, String>((ref, feedId) {
      return FeedService.instance.bookshelfCapabilities(feedId: feedId);
    });

/// The feed currently selected by the user (used as the source for searches).
class SelectedFeedNotifier extends Notifier<FeedMetaItem?> {
  @override
  FeedMetaItem? build() => null;

  void select(FeedMetaItem feed) => state = feed;
  void clear() => state = null;
}

final selectedFeedProvider =
    NotifierProvider<SelectedFeedNotifier, FeedMetaItem?>(
      SelectedFeedNotifier.new,
    );

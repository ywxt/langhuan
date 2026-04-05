import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/bindings/signals/signals.dart';
import '../feeds/feed_service.dart';

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
    this.feedId = '',
    this.bookId = '',
    this.chapterId = '',
    this.items = const [],
    this.isLoading = false,
    this.error,
    this.requestId,
  });

  final String feedId;
  final String bookId;
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
    String? feedId,
    String? bookId,
    String? chapterId,
    List<ParagraphContent>? items,
    bool? isLoading,
    Object? Function()? error,
    String? Function()? requestId,
  }) {
    return ChapterContentState(
      feedId: feedId ?? this.feedId,
      bookId: bookId ?? this.bookId,
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

  Future<void> load({
    required String feedId,
    required String bookId,
    required String chapterId,
  }) async {
    await _cancelCurrent();

    state = ChapterContentState(
      feedId: feedId,
      bookId: bookId,
      chapterId: chapterId,
      isLoading: true,
    );

    final (:requestId, :stream) = FeedService.instance.chapterContent(
      feedId: feedId,
      bookId: bookId,
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

  Future<void> retry() async {
    if (state.feedId.isEmpty ||
        state.bookId.isEmpty ||
        state.chapterId.isEmpty) {
      return;
    }
    await load(
      feedId: state.feedId,
      bookId: state.bookId,
      chapterId: state.chapterId,
    );
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

final bookshelfCapabilitiesProvider =
    FutureProvider.family<BookshelfCapabilitiesModel, String>((ref, feedId) {
      return FeedService.instance.bookshelfCapabilities(feedId: feedId);
    });

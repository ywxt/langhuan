import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/rust/api/types.dart';
import '../feeds/feed_providers.dart';
import '../feeds/feed_service.dart';
import 'bookshelf_provider.dart';

// ---------------------------------------------------------------------------
// Chapters state
// ---------------------------------------------------------------------------

class ChaptersState {
  const ChaptersState({
    this.feedId = '',
    this.bookId = '',
    this.items = const [],
    this.isLoading = false,
    this.error,
  });

  final String feedId;
  final String bookId;
  final List<ChapterInfoModel> items;
  final bool isLoading;
  final Object? error;

  bool get hasError => error != null;

  ChaptersState copyWith({
    String? feedId,
    String? bookId,
    List<ChapterInfoModel>? items,
    bool? isLoading,
    Object? Function()? error,
  }) {
    return ChaptersState(
      feedId: feedId ?? this.feedId,
      bookId: bookId ?? this.bookId,
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
      error: error != null ? error() : this.error,
    );
  }
}

class ChaptersNotifier extends Notifier<ChaptersState> {
  int _runToken = 0;

  @override
  ChaptersState build() => const ChaptersState();

  Future<void> load({required String feedId, required String bookId}) async {
    _runToken++;
    final runToken = _runToken;

    final isSameBook = state.feedId == feedId && state.bookId == bookId;
    state = isSameBook
        ? state.copyWith(isLoading: true, error: () => null)
        : ChaptersState(feedId: feedId, bookId: bookId, isLoading: true);

    try {
      final items = await ref
          .read(feedServiceProvider)
          .chapters(feedId: feedId, bookId: bookId)
          .toList();
      if (runToken != _runToken) return;

      state = state.copyWith(items: items, isLoading: false);

      // The user has seen this book's chapter list: record the baseline so
      // the next update check clears its badge.
      if (items.isNotEmpty) {
        unawaited(
          ref.read(feedServiceProvider).markBookshelfSeen(
            feedId: feedId,
            sourceBookId: bookId,
            chapterCount: items.length,
          ),
        );
        ref.read(bookshelfUpdatesProvider.notifier).clear(feedId, bookId);
      }
    } catch (err) {
      if (runToken == _runToken) {
        state = state.copyWith(isLoading: false, error: () => err);
      }
    }
  }

  Future<void> cancel() async => _runToken++;

  Future<void> retry({required String feedId}) async {
    if (state.bookId.isEmpty) return;
    await load(feedId: feedId, bookId: state.bookId);
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
    final isSameBook = state.feedId == feedId && state.bookId == bookId;
    state = isSameBook
        ? state.copyWith(isLoading: true, error: () => null)
        : BookInfoState(feedId: feedId, bookId: bookId, isLoading: true);

    try {
      final book = await ref.read(feedServiceProvider).bookInfo(
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
        book: isSameBook ? null : () => null,
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
  });

  final String feedId;
  final String bookId;
  final String chapterId;
  final List<ParagraphContent> items;
  final bool isLoading;
  final Object? error;

  bool get hasError => error != null;
  List<String> get allParagraphs => items
      .whereType<ParagraphContent_Text>()
      .map((p) => p.content)
      .toList(growable: false);

  ChapterContentState copyWith({
    String? feedId,
    String? bookId,
    String? chapterId,
    List<ParagraphContent>? items,
    bool? isLoading,
    Object? Function()? error,
  }) {
    return ChapterContentState(
      feedId: feedId ?? this.feedId,
      bookId: bookId ?? this.bookId,
      chapterId: chapterId ?? this.chapterId,
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
      error: error != null ? error() : this.error,
    );
  }
}

class ChapterContentNotifier extends Notifier<ChapterContentState> {
  int _runToken = 0;

  @override
  ChapterContentState build() => const ChapterContentState();

  Future<void> load({
    required String feedId,
    required String bookId,
    required String chapterId,
  }) async {
    final runToken = ++_runToken;

    state = ChapterContentState(
      feedId: feedId,
      bookId: bookId,
      chapterId: chapterId,
      isLoading: true,
    );

    try {
      final items = await ref
          .read(feedServiceProvider)
          .paragraphs(feedId: feedId, bookId: bookId, chapterId: chapterId)
          .toList();
      if (runToken != _runToken) return;

      state = state.copyWith(items: items, isLoading: false);
    } catch (err) {
      if (runToken == _runToken) {
        state = state.copyWith(isLoading: false, error: () => err);
      }
    }
  }

  Future<void> cancel() async => _runToken++;

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

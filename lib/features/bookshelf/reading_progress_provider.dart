import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../feeds/feed_service.dart';

// ---------------------------------------------------------------------------
// Reading progress state
// ---------------------------------------------------------------------------

class ReadingProgressState {
  const ReadingProgressState({
    this.feedId = '',
    this.bookId = '',
    this.progress,
    this.isLoading = false,
    this.isSaving = false,
    this.error,
  });

  final String feedId;
  final String bookId;
  final ReadingProgressModel? progress;
  final bool isLoading;
  final bool isSaving;
  final Object? error;

  ReadingProgressState copyWith({
    String? feedId,
    String? bookId,
    ReadingProgressModel? Function()? progress,
    bool? isLoading,
    bool? isSaving,
    Object? Function()? error,
  }) {
    return ReadingProgressState(
      feedId: feedId ?? this.feedId,
      bookId: bookId ?? this.bookId,
      progress: progress != null ? progress() : this.progress,
      isLoading: isLoading ?? this.isLoading,
      isSaving: isSaving ?? this.isSaving,
      error: error != null ? error() : this.error,
    );
  }
}

class ReadingProgressNotifier extends Notifier<ReadingProgressState> {
  @override
  ReadingProgressState build() => const ReadingProgressState();

  Future<void> load({required String feedId, required String bookId}) async {
    state = state.copyWith(
      feedId: feedId,
      bookId: bookId,
      isLoading: true,
      error: () => null,
    );

    try {
      final progress = await FeedService.instance.getReadingProgress(
        feedId: feedId,
        bookId: bookId,
      );
      state = state.copyWith(
        progress: () => progress,
        isLoading: false,
        error: () => null,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: () => e);
    }
  }

  Future<void> save({
    required String feedId,
    required String bookId,
    required String chapterId,
    required int paragraphIndex,
    required double scrollOffset,
    int? updatedAtMs,
  }) async {
    final timestamp = updatedAtMs ?? DateTime.now().millisecondsSinceEpoch;

    state = state.copyWith(
      feedId: feedId,
      bookId: bookId,
      isSaving: true,
      error: () => null,
    );

    try {
      await FeedService.instance.setReadingProgress(
        feedId: feedId,
        bookId: bookId,
        chapterId: chapterId,
        paragraphIndex: paragraphIndex,
        scrollOffset: scrollOffset,
        updatedAtMs: timestamp,
      );

      state = state.copyWith(
        progress: () => ReadingProgressModel(
          feedId: feedId,
          bookId: bookId,
          chapterId: chapterId,
          paragraphIndex: paragraphIndex,
          scrollOffset: scrollOffset,
          updatedAtMs: timestamp,
        ),
        isSaving: false,
        error: () => null,
      );
    } catch (e) {
      state = state.copyWith(isSaving: false, error: () => e);
    }
  }

  void clear() => state = const ReadingProgressState();
}

final readingProgressProvider =
    NotifierProvider<ReadingProgressNotifier, ReadingProgressState>(
      ReadingProgressNotifier.new,
    );

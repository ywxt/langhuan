import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../feeds/feed_service.dart';

class ReadingProgressState {
  const ReadingProgressState({
    this.feedId = '',
    this.bookId = '',
    this.activeChapterId = '',
    this.activeParagraphIndex = 0,
    this.activeParagraphOffset = 0,
    this.progress,
    this.isLoading = false,
    this.isSaving = false,
    this.error,
  });

  final String feedId;
  final String bookId;
  final String activeChapterId;
  final int activeParagraphIndex;
  final double activeParagraphOffset;
  final ReadingProgressModel? progress;
  final bool isLoading;
  final bool isSaving;
  final Object? error;

  ReadingProgressState copyWith({
    String? feedId,
    String? bookId,
    String? activeChapterId,
    int? activeParagraphIndex,
    double? activeParagraphOffset,
    ReadingProgressModel? Function()? progress,
    bool? isLoading,
    bool? isSaving,
    Object? Function()? error,
  }) {
    return ReadingProgressState(
      feedId: feedId ?? this.feedId,
      bookId: bookId ?? this.bookId,
      activeChapterId: activeChapterId ?? this.activeChapterId,
      activeParagraphIndex: activeParagraphIndex ?? this.activeParagraphIndex,
      activeParagraphOffset:
          activeParagraphOffset ?? this.activeParagraphOffset,
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

  void hydrateInitialPosition({
    required String chapterId,
    required int paragraphIndex,
    double paragraphOffset = 0,
  }) {
    state = state.copyWith(
      activeChapterId: chapterId,
      activeParagraphIndex: paragraphIndex,
      activeParagraphOffset: paragraphOffset,
    );
  }

  Future<void> load({
    required String feedId,
    required String bookId,
    required String fallbackChapterId,
    int fallbackParagraphIndex = 0,
  }) async {
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
      final chapterId = progress?.chapterId ?? fallbackChapterId;
      final paragraphIndex = progress?.paragraphIndex ?? fallbackParagraphIndex;
      hydrateInitialPosition(
        chapterId: chapterId,
        paragraphIndex: paragraphIndex,
      );
      state = state.copyWith(
        progress: () => progress,
        isLoading: false,
        error: () => null,
      );
    } catch (e) {
      hydrateInitialPosition(
        chapterId: fallbackChapterId,
        paragraphIndex: fallbackParagraphIndex,
      );
      state = state.copyWith(isLoading: false, error: () => e);
    }
  }

  void setActiveChapter(String chapterId, {int paragraphIndex = 0}) {
    state = state.copyWith(
      activeChapterId: chapterId,
      activeParagraphIndex: paragraphIndex,
      activeParagraphOffset: 0,
    );
  }

  void setActiveParagraph(int paragraphIndex) {
    state = state.copyWith(activeParagraphIndex: paragraphIndex);
  }

  void setActiveOffset(double offset) {
    state = state.copyWith(activeParagraphOffset: offset);
  }

  Future<void> saveActive({int? updatedAtMs}) async {
    if (state.feedId.isEmpty ||
        state.bookId.isEmpty ||
        state.activeChapterId.isEmpty) {
      return;
    }

    final timestamp = updatedAtMs ?? DateTime.now().millisecondsSinceEpoch;
    state = state.copyWith(isSaving: true, error: () => null);

    try {
      await FeedService.instance.setReadingProgress(
        feedId: state.feedId,
        bookId: state.bookId,
        chapterId: state.activeChapterId,
        paragraphIndex: state.activeParagraphIndex,
        updatedAtMs: timestamp,
      );

      state = state.copyWith(
        progress: () => ReadingProgressModel(
          feedId: state.feedId,
          bookId: state.bookId,
          chapterId: state.activeChapterId,
          paragraphIndex: state.activeParagraphIndex,
          updatedAtMs: timestamp,
        ),
        isSaving: false,
        error: () => null,
      );
    } catch (e) {
      state = state.copyWith(isSaving: false, error: () => e);
    }
  }

  Future<void> save({
    required String feedId,
    required String bookId,
    required String chapterId,
    required int paragraphIndex,
    int? updatedAtMs,
  }) async {
    state = state.copyWith(feedId: feedId, bookId: bookId);
    hydrateInitialPosition(
      chapterId: chapterId,
      paragraphIndex: paragraphIndex,
    );
    await saveActive(updatedAtMs: updatedAtMs);
  }

  void clear() => state = const ReadingProgressState();
}

final readingProgressProvider =
    NotifierProvider<ReadingProgressNotifier, ReadingProgressState>(
      ReadingProgressNotifier.new,
    );

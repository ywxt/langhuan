import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../feeds/feed_providers.dart';
import '../feeds/feed_service.dart';

class ReadingProgressState {
  const ReadingProgressState({
    this.feedId = '',
    this.bookId = '',
    this.activeChapterId = '',
    this.activeParagraphId = '',
    this.activeParagraphOffset = 0,
    this.activeParagraphCharOffset = 0,
    this.progress,
    this.isLoading = false,
    this.isSaving = false,
    this.error,
  });

  final String feedId;
  final String bookId;
  final String activeChapterId;
  final String activeParagraphId;
  final double activeParagraphOffset;

  /// Character offset of the page-leading character within the active
  /// paragraph (horizontal mode); persisted so page-precise restore works
  /// when a paragraph spans pages.
  final int activeParagraphCharOffset;

  final ReadingProgressModel? progress;
  final bool isLoading;
  final bool isSaving;
  final Object? error;

  ReadingProgressState copyWith({
    String? feedId,
    String? bookId,
    String? activeChapterId,
    String? activeParagraphId,
    double? activeParagraphOffset,
    int? activeParagraphCharOffset,
    ReadingProgressModel? Function()? progress,
    bool? isLoading,
    bool? isSaving,
    Object? Function()? error,
  }) {
    return ReadingProgressState(
      feedId: feedId ?? this.feedId,
      bookId: bookId ?? this.bookId,
      activeChapterId: activeChapterId ?? this.activeChapterId,
      activeParagraphId: activeParagraphId ?? this.activeParagraphId,
      activeParagraphOffset:
          activeParagraphOffset ?? this.activeParagraphOffset,
      activeParagraphCharOffset:
          activeParagraphCharOffset ?? this.activeParagraphCharOffset,
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
    required String paragraphId,
    double paragraphOffset = 0,
    int paragraphCharOffset = 0,
  }) {
    state = state.copyWith(
      activeChapterId: chapterId,
      activeParagraphId: paragraphId,
      activeParagraphOffset: paragraphOffset,
      activeParagraphCharOffset: paragraphCharOffset,
    );
  }

  Future<void> load({
    required String feedId,
    required String bookId,
    required String fallbackChapterId,
    String fallbackParagraphId = '',
  }) async {
    state = state.copyWith(
      feedId: feedId,
      bookId: bookId,
      isLoading: true,
      error: () => null,
    );

    try {
      final progress = await ref
          .read(feedServiceProvider)
          .getReadingProgress(feedId: feedId, bookId: bookId);
      final chapterId = progress?.chapterId ?? fallbackChapterId;
      final paragraphId = progress?.paragraphId ?? fallbackParagraphId;
      hydrateInitialPosition(
        chapterId: chapterId,
        paragraphId: paragraphId,
        paragraphCharOffset: progress?.paragraphCharOffset ?? 0,
      );
      state = state.copyWith(
        progress: () => progress,
        isLoading: false,
        error: () => null,
      );
    } catch (e) {
      hydrateInitialPosition(
        chapterId: fallbackChapterId,
        paragraphId: fallbackParagraphId,
      );
      state = state.copyWith(isLoading: false, error: () => e);
    }
  }

  void setActiveChapter(String chapterId, {String paragraphId = ''}) {
    state = state.copyWith(
      activeChapterId: chapterId,
      activeParagraphId: paragraphId,
      activeParagraphOffset: 0,
      activeParagraphCharOffset: 0,
    );
  }

  void setActivePosition({
    required String chapterId,
    required String paragraphId,
    required double paragraphOffset,
    required int paragraphCharOffset,
  }) {
    state = state.copyWith(
      activeChapterId: chapterId,
      activeParagraphId: paragraphId,
      activeParagraphOffset: paragraphOffset,
      activeParagraphCharOffset: paragraphCharOffset,
    );
  }

  void setActiveParagraph(String paragraphId) {
    state = state.copyWith(activeParagraphId: paragraphId);
  }

  void setActiveOffset(double offset) {
    state = state.copyWith(activeParagraphOffset: offset);
  }

  void setActiveCharOffset(int charOffset) {
    state = state.copyWith(activeParagraphCharOffset: charOffset);
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
      await ref
          .read(feedServiceProvider)
          .setReadingProgress(
            feedId: state.feedId,
            bookId: state.bookId,
            chapterId: state.activeChapterId,
            paragraphId: state.activeParagraphId,
            paragraphCharOffset: state.activeParagraphCharOffset,
            updatedAtMs: timestamp,
          );

      state = state.copyWith(
        progress: () => ReadingProgressModel(
          feedId: state.feedId,
          bookId: state.bookId,
          chapterId: state.activeChapterId,
          paragraphId: state.activeParagraphId,
          paragraphCharOffset: state.activeParagraphCharOffset,
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
    required String paragraphId,
    int paragraphCharOffset = 0,
    int? updatedAtMs,
  }) async {
    state = state.copyWith(feedId: feedId, bookId: bookId);
    hydrateInitialPosition(
      chapterId: chapterId,
      paragraphId: paragraphId,
      paragraphCharOffset: paragraphCharOffset,
    );
    await saveActive(updatedAtMs: updatedAtMs);
  }

  void clear() => state = const ReadingProgressState();
}

final readingProgressProvider =
    NotifierProvider<ReadingProgressNotifier, ReadingProgressState>(
      ReadingProgressNotifier.new,
    );

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/rust/api/types.dart';
import '../feeds/feed_service.dart';
import 'bookmark_provider.dart';
import 'book_providers.dart';
import 'reading_progress_provider.dart';
import 'widgets/reader_controller.dart';
import 'widgets/reader_types.dart';

class ReaderScreenController extends ChangeNotifier {
  ReaderScreenController({
    required WidgetRef ref,
    required ReaderController readerController,
    required this.feedId,
    required this.bookId,
    required this.initialChapterId,
    required this.initialParagraphId,
  }) : _ref = ref,
       _readerController = readerController;

  static const _saveDebounce = Duration(milliseconds: 400);
  static const _offsetEpsilon = 0.5;

  final WidgetRef _ref;
  final ReaderController _readerController;

  final String feedId;
  final String bookId;
  final String initialChapterId;
  final String initialParagraphId;

  bool _isInitializing = false;
  Object? _initError;
  List<ChapterInfoModel> _chapters = const [];
  bool _showControls = false;
  bool _isRefreshingChapter = false;
  ParagraphSelection? _selection;

  Timer? _progressSaveTimer;
  _PendingProgress? _pendingProgress;
  _PendingProgress? _lastSavedProgress;

  bool _disposed = false;

  bool get isInitializing => _isInitializing;
  Object? get initError => _initError;
  List<ChapterInfoModel> get chapters => _chapters;
  bool get showControls => _showControls;
  bool get isRefreshingChapter => _isRefreshingChapter;
  ParagraphSelection? get selection => _selection;

  Future<void> initialize() async {
    if (feedId.isEmpty || bookId.isEmpty) return;

    _isInitializing = true;
    _initError = null;
    _notify();

    try {
      final chapters = await FeedService.instance
          .chapters(feedId: feedId, bookId: bookId)
          .toList();

      final fallbackChapterId = _resolveInitialChapterId(chapters);
      final fallbackParagraphId = fallbackChapterId == initialChapterId
          ? initialParagraphId
          : '';

      final progressNotifier = _ref.read(readingProgressProvider.notifier);
      await progressNotifier.load(
        feedId: feedId,
        bookId: bookId,
        fallbackChapterId: fallbackChapterId,
        fallbackParagraphId: fallbackParagraphId,
      );

      final activeId = _ref.read(readingProgressProvider).activeChapterId;
      if (chapters.isNotEmpty && !chapters.any((c) => c.id == activeId)) {
        progressNotifier.setActiveChapter(chapters.first.id);
      }

      _chapters = chapters;
      _isInitializing = false;
      _notify();

      final String startChapterId;
      final String startParagraphId;
      final int startCharOffset;
      if (initialChapterId.isNotEmpty &&
          chapters.any((c) => c.id == initialChapterId)) {
        startChapterId = initialChapterId;
        startParagraphId = initialParagraphId;
        startCharOffset = 0;
      } else {
        final reading = _ref.read(readingProgressProvider);
        startChapterId = reading.activeChapterId;
        startParagraphId = reading.activeParagraphId;
        startCharOffset = reading.activeParagraphCharOffset;
      }
      _readerController.jumpTo(
        chapterId: startChapterId,
        paragraphId: startParagraphId,
        charOffset: startCharOffset,
      );

      unawaited(
        _ref
            .read(bookInfoProvider.notifier)
            .load(feedId: feedId, bookId: bookId),
      );
      unawaited(
        _ref
            .read(bookmarkProvider.notifier)
            .load(feedId: feedId, bookId: bookId),
      );
    } catch (error) {
      _isInitializing = false;
      _initError = error;
      _notify();
    }
  }

  void onPositionChanged(ReaderPosition pos) {
    final progressNotifier = _ref.read(readingProgressProvider.notifier);
    progressNotifier.setActiveChapter(
      pos.chapterId,
      paragraphId: pos.paragraphId,
    );
    progressNotifier.setActiveOffset(pos.paragraphOffset);
    progressNotifier.setActiveCharOffset(pos.charOffset);

    if (pos.paragraphId.trim().isEmpty) return;

    final pending = _PendingProgress(
      chapterId: pos.chapterId,
      paragraphId: pos.paragraphId,
      paragraphOffset: pos.paragraphOffset,
      charOffset: pos.charOffset,
    );

    if (_pendingProgress?.isNear(pending, _offsetEpsilon) ?? false) return;
    _pendingProgress = pending;

    _progressSaveTimer?.cancel();
    _progressSaveTimer = Timer(_saveDebounce, _flushPendingProgress);
  }

  void toggleControls() {
    if (_selection != null) {
      _selection = null;
      _notify();
      return;
    }
    _showControls = !_showControls;
    _notify();
  }

  void hideControls() {
    if (!_showControls) return;
    _showControls = false;
    _notify();
  }

  void jumpToChapter(String chapterId, {String paragraphId = ''}) {
    _readerController.jumpTo(chapterId: chapterId, paragraphId: paragraphId);
  }

  Future<void> refreshCurrentChapter(String chapterId) async {
    if (_isRefreshingChapter || chapterId.isEmpty) return;

    _isRefreshingChapter = true;
    _notify();
    try {
      await FeedService.instance
          .paragraphs(
            feedId: feedId,
            bookId: bookId,
            chapterId: chapterId,
            forceRefresh: true,
          )
          .drain<void>();
      // The backend cache is warm now — make the reader re-read the chapter
      // so the new content actually shows.
      _readerController.requestChapterReload(chapterId);
    } finally {
      _isRefreshingChapter = false;
      _notify();
    }
  }

  Future<bool> addBookmark({
    required String chapterId,
    required String paragraphId,
    required ParagraphContent paragraph,
  }) async {
    if (chapterId.isEmpty) return false;
    final preview = _paragraphPreview(paragraph);
    final created = await _ref
        .read(bookmarkProvider.notifier)
        .add(
          feedId: feedId,
          bookId: bookId,
          chapterId: chapterId,
          paragraphId: paragraphId,
          paragraphName: preview,
          paragraphPreview: preview,
        );
    return created != null;
  }

  void setSelection({
    required String chapterId,
    required String paragraphId,
    required ParagraphContent paragraph,
    required Rect globalRect,
  }) {
    // Selection actions must not sit underneath the reader chrome. This is
    // especially important in horizontal mode, where the first paragraph's
    // action toolbar occupies the same vertical band as the top controls.
    _showControls = false;
    _selection = ParagraphSelection(
      chapterId: chapterId,
      paragraphId: paragraphId,
      paragraph: paragraph,
      rect: globalRect,
    );
    _notify();
  }

  void clearSelection() {
    if (_selection == null) return;
    _selection = null;
    _notify();
  }

  String _resolveInitialChapterId(List<ChapterInfoModel> chapters) {
    if (initialChapterId.isNotEmpty &&
        chapters.any((chapter) => chapter.id == initialChapterId)) {
      return initialChapterId;
    }
    if (chapters.isNotEmpty) {
      return chapters.first.id;
    }
    return '';
  }

  String _paragraphPreview(ParagraphContent paragraph) {
    final text = switch (paragraph) {
      ParagraphContent_Title(:final text) => text,
      ParagraphContent_Text(:final content) => content,
      ParagraphContent_Image(:final alt) => alt ?? '',
    };
    final trimmed = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    return trimmed.length > 20 ? '${trimmed.substring(0, 20)}…' : trimmed;
  }

  void _flushPendingProgress() {
    final pending = _pendingProgress;
    if (pending == null) return;
    if (_lastSavedProgress?.isNear(pending, _offsetEpsilon) ?? false) return;

    _lastSavedProgress = pending;
    unawaited(
      _ref
          .read(readingProgressProvider.notifier)
          .save(
            feedId: feedId,
            bookId: bookId,
            chapterId: pending.chapterId,
            paragraphId: pending.paragraphId,
            paragraphCharOffset: pending.charOffset,
          ),
    );
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _progressSaveTimer?.cancel();
    _progressSaveTimer = null;
    super.dispose();
  }
}

class _PendingProgress {
  const _PendingProgress({
    required this.chapterId,
    required this.paragraphId,
    required this.paragraphOffset,
    this.charOffset = 0,
  });

  final String chapterId;
  final String paragraphId;
  final double paragraphOffset;

  /// Character offset of the page-leading character within the paragraph
  /// (horizontal mode).
  final int charOffset;

  bool isNear(_PendingProgress other, double epsilon) {
    return chapterId == other.chapterId &&
        paragraphId == other.paragraphId &&
        (paragraphOffset - other.paragraphOffset).abs() <= epsilon &&
        charOffset == other.charOffset;
  }
}

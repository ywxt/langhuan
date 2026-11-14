import 'package:flutter/foundation.dart';

import 'reader_types.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Reader position — reported from content views to the parent
// ─────────────────────────────────────────────────────────────────────────────

class ReaderPosition {
  const ReaderPosition({
    required this.chapterId,
    required this.paragraphId,
    this.paragraphOffset = 0,
    this.charOffset = 0,
  });

  final String chapterId;
  final String paragraphId;
  final double paragraphOffset;

  /// Character offset of the page-leading character within the paragraph
  /// (horizontal mode). Distinguishes a paragraph's start page from its
  /// continuation page so progress can be restored page-precisely.
  final int charOffset;
}

// ─────────────────────────────────────────────────────────────────────────────
// Reader controller
//
// Two-way communication channel between ReaderPage and ChapterContentManager.
//
//   ReaderPage → jumpTo() → ChapterContentManager  (imperative command)
//   ChapterContentManager → reportPosition() → ReaderPage  (position callback)
//
// This is a ChangeNotifier so the content manager can listen for jump commands
// without requiring widget rebuilds.
// ─────────────────────────────────────────────────────────────────────────────

class ReaderController extends ChangeNotifier {
  // ─ Jump command (parent → content manager) ─────────────────────────────

  String? _pendingChapterId;
  String _pendingParagraphId = '';
  double _pendingParagraphOffset = 0;
  int _pendingCharOffset = 0;

  String? get pendingChapterId => _pendingChapterId;
  String get pendingParagraphId => _pendingParagraphId;
  double get pendingParagraphOffset => _pendingParagraphOffset;
  double get pendingOffset => _pendingParagraphOffset;
  int get pendingCharOffset => _pendingCharOffset;

  void jumpTo({
    required String chapterId,
    String paragraphId = '',
    double paragraphOffset = 0,
    int charOffset = 0,
  }) {
    _pendingChapterId = chapterId;
    _pendingParagraphId = paragraphId;
    _pendingParagraphOffset = paragraphOffset;
    _pendingCharOffset = charOffset;
    notifyListeners();
  }

  /// Rendering adapters expose visibility and cancel deferred positioning.
  bool Function(String chapterId, String paragraphId)? isParagraphVisible;
  VoidCallback? onCancelPendingNavigation;

  void cancelPendingNavigation() {
    consumeJump();
    onCancelPendingNavigation?.call();
  }

  void consumeJump() {
    _pendingChapterId = null;
    _pendingParagraphId = '';
    _pendingParagraphOffset = 0;
    _pendingCharOffset = 0;
  }

  // ─ Chapter result (parent → content manager) ───────────────────────────

  ({String chapterId, ChapterLoadState state})? _pendingChapterState;

  /// Publish the result of an explicit refresh without fetching it again.
  void updateChapter(String chapterId, ChapterLoadState state) {
    _pendingChapterState = (chapterId: chapterId, state: state);
    notifyListeners();
  }

  ({String chapterId, ChapterLoadState state})? consumeChapterUpdate() {
    final value = _pendingChapterState;
    _pendingChapterState = null;
    return value;
  }

  // ─ Position reporting (content manager → parent) ───────────────────────

  /// External listener for position changes — set by ReaderPage to save
  /// reading progress. The content manager never reads this.
  ValueChanged<ReaderPosition>? onPositionChanged;

  void reportPosition({
    required String chapterId,
    required String paragraphId,
    double paragraphOffset = 0,
    int charOffset = 0,
  }) {
    onPositionChanged?.call(
      ReaderPosition(
        chapterId: chapterId,
        paragraphId: paragraphId,
        paragraphOffset: paragraphOffset,
        charOffset: charOffset,
      ),
    );
  }
}

import 'package:flutter/foundation.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Reader position — reported from content views to the parent
// ─────────────────────────────────────────────────────────────────────────────

class ReaderPosition {
  const ReaderPosition({
    required this.chapterId,
    required this.paragraphIndex,
    this.offset = 0,
  });

  final String chapterId;
  final int paragraphIndex;
  final double offset;
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
  int _pendingParagraphIndex = 0;
  double _pendingOffset = 0;

  String? get pendingChapterId => _pendingChapterId;
  int get pendingParagraphIndex => _pendingParagraphIndex;
  double get pendingOffset => _pendingOffset;

  /// Request a jump to a specific chapter and paragraph.
  /// The content manager listens via [addListener] and consumes the pending
  /// jump in the next frame.
  void jumpTo({
    required String chapterId,
    int paragraphIndex = 0,
    double offset = 0,
  }) {
    _pendingChapterId = chapterId;
    _pendingParagraphIndex = paragraphIndex;
    _pendingOffset = offset;
    notifyListeners();
  }

  /// Called by the content manager after consuming the jump.
  void consumeJump() {
    _pendingChapterId = null;
    _pendingParagraphIndex = 0;
    _pendingOffset = 0;
  }

  // ─ Position reporting (content manager → parent) ───────────────────────

  /// External listener for position changes — set by ReaderPage to save
  /// reading progress. The content manager never reads this.
  ValueChanged<ReaderPosition>? onPositionChanged;

  /// Called by the content views when the visible chapter/paragraph changes.
  void reportPosition({
    required String chapterId,
    required int paragraphIndex,
    double offset = 0,
  }) {
    onPositionChanged?.call(ReaderPosition(
      chapterId: chapterId,
      paragraphIndex: paragraphIndex,
      offset: offset,
    ));
  }
}

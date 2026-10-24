import 'package:flutter/foundation.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Reader position — reported from content views to the parent
// ─────────────────────────────────────────────────────────────────────────────

class ReaderPosition {
  const ReaderPosition({
    required this.chapterId,
    required this.paragraphId,
    this.paragraphOffset = 0,
  });

  final String chapterId;
  final String paragraphId;
  final double paragraphOffset;

  // Backward-compatible alias for older call sites.
  double get offset => paragraphOffset;
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

  String? get pendingChapterId => _pendingChapterId;
  String get pendingParagraphId => _pendingParagraphId;
  double get pendingParagraphOffset => _pendingParagraphOffset;
  double get pendingOffset => _pendingParagraphOffset;

  void jumpTo({
    required String chapterId,
    String paragraphId = '',
    double paragraphOffset = 0,
  }) {
    _pendingChapterId = chapterId;
    _pendingParagraphId = paragraphId;
    _pendingParagraphOffset = paragraphOffset;
    notifyListeners();
  }

  void consumeJump() {
    _pendingChapterId = null;
    _pendingParagraphId = '';
    _pendingParagraphOffset = 0;
  }

  // ─ Reload command (parent → content manager) ───────────────────────────

  String? _pendingReloadChapterId;

  String? get pendingReloadChapterId => _pendingReloadChapterId;

  /// Ask the content manager to re-read a chapter (e.g. after the pull
  /// refresh warmed the backend cache).
  void requestChapterReload(String chapterId) {
    _pendingReloadChapterId = chapterId;
    notifyListeners();
  }

  String? consumeChapterReload() {
    final value = _pendingReloadChapterId;
    _pendingReloadChapterId = null;
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
  }) {
    onPositionChanged?.call(
      ReaderPosition(
        chapterId: chapterId,
        paragraphId: paragraphId,
        paragraphOffset: paragraphOffset,
      ),
    );
  }
}

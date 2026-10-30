import 'package:flutter/foundation.dart';

import '../../../shared/utils/app_log.dart';

import '../../../src/rust/api/types.dart';
import '../../feeds/feed_service.dart' show ChapterInfoModel;
import 'reader_types.dart';

/// Loads the paragraphs of one chapter.
///
/// `forceRefresh` bypasses the on-disk cache (used by pull-to-refresh).
typedef ChapterParagraphLoader =
    Future<List<ParagraphContent>> Function(
      String chapterId, {
      bool forceRefresh,
    });

/// Reported by [ReaderChapterWindow.maintainAround] when the anchor chapter
/// moves. The vertical reader uses it to correct its scroll offset by the
/// pixel extent between the two anchors *before* the next frame paints.
class WindowReanchor {
  const WindowReanchor({
    required this.oldAnchorChapterId,
    required this.newAnchorChapterId,
  });

  final String oldAnchorChapterId;
  final String newAnchorChapterId;
}

/// A contiguous, expandable window of chapters around an *anchor* chapter.
///
/// The window is the single source of truth for which chapters are rendered
/// and what state each is in. It can grow at both ends ([expandAbove],
/// [expandBelow]) as the user scrolls toward its edges, and [maintainAround]
/// keeps it bounded by re-anchoring and trimming ends that drifted far from
/// the reading position.
///
/// Paragraph data is cached beyond the window's lifetime (bounded LRU) so
/// jumping back reuses earlier fetches.
///
/// This class is plain logic on top of [ChangeNotifier] — no rendering, no
/// scroll positions — which keeps it fully unit-testable.
class ReaderChapterWindow extends ChangeNotifier {
  ReaderChapterWindow({
    required List<ChapterInfoModel> chapters,
    required String anchorChapterId,
    required ChapterParagraphLoader loader,
    int maxWindowChapters = 8,
    int cacheCap = 24,
  }) : _chapters = List.of(chapters),
       _loader = loader,
       _maxWindowChapters = maxWindowChapters,
       _cacheCap = cacheCap {
    final anchorIdx = _indexOf(anchorChapterId);
    _resetAround(anchorIdx >= 0 ? anchorIdx : 0);
  }

  /// Window covers at most this many chapters after [maintainAround].
  final int _maxWindowChapters;

  /// Paragraph cache retention cap (chapters kept beyond the window).
  final int _cacheCap;

  /// Re-anchor once the active chapter drifts this far from the anchor.
  static const _reanchorDistance = 3;

  /// Never trim within this many chapters of the active chapter.
  static const _keepAdjacent = 1;

  List<ChapterInfoModel> _chapters;
  final ChapterParagraphLoader _loader;

  /// Inclusive index bounds of the window into [_chapters].
  int _lo = 0;
  int _hi = 0;
  int _anchorIdx = 0;

  /// Load state per window member (chapters currently rendered).
  final Map<String, ChapterLoadState> _records = {};

  /// Paragraph cache — survives trims, bounded LRU.
  final Map<String, List<ParagraphContent>> _cache = {};

  /// In-flight loads keyed by chapter id.
  final Map<String, Future<void>> _inFlight = {};

  // ── Getters ─────────────────────────────────────────────────────────────

  List<ChapterInfoModel> get chapters => _chapters;

  String get anchorChapterId =>
      _chapters.isEmpty ? '' : _chapters[_anchorIdx].id;

  /// Window member chapter ids in reading order.
  List<String> get windowChapterIds => [
    for (var i = _lo; i <= _hi; i++) _chapters[i].id,
  ];

  bool get hasChapterAbove => _lo > 0;

  bool get hasChapterBelow => _hi < _chapters.length - 1;

  /// The chapter above the window top, if any (used to pre-load).
  String? get firstChapterAboveId =>
      hasChapterAbove ? _chapters[_lo - 1].id : null;

  ChapterLoadState stateOf(String chapterId) =>
      _records[chapterId] ?? const ChapterIdle();

  List<ParagraphContent>? paragraphsOf(String chapterId) {
    final state = _records[chapterId];
    if (state is ChapterLoaded) return state.paragraphs;
    return _cache[chapterId];
  }

  // ── Source changes ──────────────────────────────────────────────────────

  /// Replace the chapter list entirely (book/source switched) and anchor
  /// around [anchorChapterId].
  void setChapters(List<ChapterInfoModel> chapters, String anchorChapterId) {
    _chapters = List.of(chapters);
    _cache.clear();
    _inFlight.clear();
    final anchorIdx = _indexOf(anchorChapterId);
    _resetAround(anchorIdx >= 0 ? anchorIdx : 0);
  }

  /// Drop all cached paragraph data and reload the current window (used when
  /// the conversion setting changes — paragraphs must be re-fetched).
  void reloadWindow() {
    _cache.clear();
    _resetAround(_anchorIdx);
  }

  // ── Expansion ───────────────────────────────────────────────────────────

  /// Extend the window one chapter upward and load that chapter.
  ///
  /// No-op at the book start, or while the current top chapter is still
  /// loading (rapid-fire calls collapse into one expansion).
  void expandAbove() {
    if (!hasChapterAbove) return;
    if (_records[_chapters[_lo].id] is ChapterLoading) return;
    final id = _chapters[_lo - 1].id;
    _lo--;
    _records[id] = _cache.containsKey(id)
        ? ChapterLoaded(_cache[id]!)
        : const ChapterLoading();
    _notify();
    _loadChapter(id);
  }

  /// Extend the window one chapter downward and load that chapter.
  void expandBelow() {
    if (!hasChapterBelow) return;
    if (_records[_chapters[_hi].id] is ChapterLoading) return;
    final id = _chapters[_hi + 1].id;
    _hi++;
    _records[id] = _cache.containsKey(id)
        ? ChapterLoaded(_cache[id]!)
        : const ChapterLoading();
    _notify();
    _loadChapter(id);
  }

  /// Retry a window chapter that previously failed to load.
  void retry(String chapterId) {
    if (!_records.containsKey(chapterId)) return;
    if (_records[chapterId] is! ChapterLoadError) return;
    _records[chapterId] = const ChapterLoading();
    _notify();
    _loadChapter(chapterId);
  }

  /// Reload one chapter, dropping its cached paragraphs first. With
  /// [forceRefresh] the fetch bypasses the on-disk cache too.
  Future<void> reload(String chapterId, {bool forceRefresh = false}) async {
    if (!_records.containsKey(chapterId)) return;
    _cache.remove(chapterId);
    _records[chapterId] = const ChapterLoading();
    _notify();
    await _loadChapter(chapterId, forceRefresh: forceRefresh);
  }

  // ── Jumping ─────────────────────────────────────────────────────────────

  /// Reset the window around [chapterId] (which becomes the new anchor) and
  /// load its neighbors. Cached chapters become available instantly.
  void jumpTo(String chapterId) {
    final idx = _indexOf(chapterId);
    if (idx < 0) return;
    _resetAround(idx);
  }

  // ── Maintenance ─────────────────────────────────────────────────────────

  /// Re-anchor and trim the window around the chapter the user is actually
  /// reading.
  ///
  /// * If [activeChapterId] drifted more than [_reanchorDistance] from the
  ///   anchor, the anchor moves onto it. [onReanchor] is invoked with the
  ///   transition *before* any state changes are applied, while all window
  ///   slivers still exist — the vertical reader uses that moment to measure
  ///   the pixel extent between the anchors and correct its scroll offset.
  /// * Ends that are far from the active chapter (and neither visible nor
  ///   the anchor) are trimmed until the window fits [_maxWindowChapters].
  ///
  /// [visibleChapterIds] names chapters currently on screen (vertical mode);
  /// they are never trimmed.
  void maintainAround(
    String activeChapterId, {
    Set<String> visibleChapterIds = const {},
    void Function(WindowReanchor reanchor)? onReanchor,
  }) {
    if (_chapters.isEmpty) return;
    final activeIdx = _indexOf(activeChapterId);
    if (activeIdx < 0) return;

    var changed = false;

    if ((activeIdx - _anchorIdx).abs() > _reanchorDistance) {
      onReanchor?.call(
        WindowReanchor(
          oldAnchorChapterId: _chapters[_anchorIdx].id,
          newAnchorChapterId: _chapters[activeIdx].id,
        ),
      );
      _anchorIdx = activeIdx;
      changed = true;
    }

    while (_hi - _lo + 1 > _maxWindowChapters) {
      final topOk =
          _lo < _anchorIdx &&
          _lo < activeIdx - _keepAdjacent &&
          !visibleChapterIds.contains(_chapters[_lo].id);
      final bottomOk =
          _hi > _anchorIdx &&
          _hi > activeIdx + _keepAdjacent &&
          !visibleChapterIds.contains(_chapters[_hi].id);

      if (topOk && (!bottomOk || activeIdx - _lo >= _hi - activeIdx)) {
        _records.remove(_chapters[_lo].id);
        _lo++;
      } else if (bottomOk) {
        _records.remove(_chapters[_hi].id);
        _hi--;
      } else {
        break;
      }
      changed = true;
    }

    if (changed) _notify();
  }

  // ── Internals ───────────────────────────────────────────────────────────

  int _indexOf(String chapterId) {
    for (var i = 0; i < _chapters.length; i++) {
      if (_chapters[i].id == chapterId) return i;
    }
    return -1;
  }

  /// Rebuild the window as `[anchor-1, anchor+1]` (clamped) and load its
  /// members. Cached chapters resolve synchronously.
  void _resetAround(int anchorIdx) {
    if (_chapters.isEmpty) {
      _lo = _hi = _anchorIdx = 0;
      _records.clear();
      _notify();
      return;
    }
    anchorIdx = anchorIdx.clamp(0, _chapters.length - 1);
    _anchorIdx = anchorIdx;
    _lo = (anchorIdx - 1).clamp(0, _chapters.length - 1);
    _hi = (anchorIdx + 1).clamp(0, _chapters.length - 1);

    _records.clear();
    for (var i = _lo; i <= _hi; i++) {
      final id = _chapters[i].id;
      _records[id] = _cache.containsKey(id)
          ? ChapterLoaded(_cache[id]!)
          : const ChapterLoading();
    }
    _notify();

    for (var i = _lo; i <= _hi; i++) {
      _loadChapter(_chapters[i].id);
    }
  }

  Future<void> _loadChapter(String chapterId, {bool forceRefresh = false}) {
    final existing = _inFlight[chapterId];
    if (existing != null && !forceRefresh) return existing;

    if (!forceRefresh && _cache.containsKey(chapterId)) {
      if (_records.containsKey(chapterId)) {
        _records[chapterId] = ChapterLoaded(_cache[chapterId]!);
        _notify();
      }
      return Future.value();
    }

    final future = _fetch(chapterId, forceRefresh);
    _inFlight[chapterId] = future;
    return future;
  }

  Future<void> _fetch(String chapterId, bool forceRefresh) async {
    final stopwatch = Stopwatch()..start();
    AppLog.debug(
      'reader.chapter_window',
      'chapter load started',
      fields: {'chapter_id': chapterId, 'force_refresh': forceRefresh},
    );
    try {
      final paragraphs = await _loader(chapterId, forceRefresh: forceRefresh);
      _putCache(chapterId, paragraphs);
      if (_records.containsKey(chapterId)) {
        _records[chapterId] = ChapterLoaded(paragraphs);
      }
      AppLog.debug(
        'reader.chapter_window',
        'chapter load completed',
        fields: {
          'chapter_id': chapterId,
          'paragraphs': paragraphs.length,
          'elapsed_ms': stopwatch.elapsedMilliseconds,
        },
      );
    } catch (error, stackTrace) {
      if (_records.containsKey(chapterId)) {
        _records[chapterId] = ChapterLoadError(error: error);
      }
      AppLog.warning(
        'reader.chapter_window',
        'chapter load failed',
        fields: {
          'chapter_id': chapterId,
          'elapsed_ms': stopwatch.elapsedMilliseconds,
        },
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _inFlight.remove(chapterId);
      _notify();
    }
  }

  void _putCache(String chapterId, List<ParagraphContent> paragraphs) {
    _cache
      ..remove(chapterId)
      ..[chapterId] = paragraphs;

    while (_cache.length > _cacheCap) {
      String? evict;
      for (final key in _cache.keys) {
        if (!_records.containsKey(key)) {
          evict = key;
          break;
        }
      }
      if (evict == null) break;
      _cache.remove(evict);
    }
  }

  void _notify() {
    if (isDisposed) return;
    notifyListeners();
  }

  bool _disposed = false;
  bool get isDisposed => _disposed;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

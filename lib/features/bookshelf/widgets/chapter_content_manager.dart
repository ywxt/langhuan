import 'dart:async';

import 'package:flutter/material.dart';

import '../../../src/rust/api/types.dart';
import '../../feeds/feed_service.dart';
import '../reader_settings_provider.dart';
import 'chapter_status_block.dart';
import 'horizontal_reader_view.dart';
import 'reader_controller.dart';
import 'reader_types.dart';
import 'vertical_reader_view.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Chapter content manager
//
// Manages a sliding window of 3 chapters (prev, center, next).
// Each slot is a ValueNotifier<ChapterLoadState> so that adjacent chapter
// loading does NOT trigger setState on this widget — only the affected
// ValueListenableBuilder in the reader view rebuilds.
//
// setState is only called for:
//   1. Initial load completion (loading overlay → content)
//   2. Window slide (explicit chapter switch — full rebuild is intentional)
//   3. Mode/font changes from didUpdateWidget
// ─────────────────────────────────────────────────────────────────────────────

class ChapterContentManager extends StatefulWidget {
  const ChapterContentManager({
    super.key,
    required this.feedId,
    required this.bookId,
    required this.chapters,
    required this.controller,
    required this.mode,
    required this.fontScale,
    required this.lineHeight,
    required this.contentPadding,
    this.onParagraphLongPress,
  });

  final String feedId;
  final String bookId;
  final List<ChapterInfoModel> chapters;
  final ReaderController controller;
  final ReaderMode mode;
  final double fontScale;
  final double lineHeight;
  final EdgeInsets contentPadding;
  final void Function(String chapterId, int paragraphIndex, ParagraphContent paragraph)? onParagraphLongPress;

  @override
  State<ChapterContentManager> createState() => _ChapterContentManagerState();
}

class _ChapterContentManagerState extends State<ChapterContentManager> {
  // ─ Chapter index helpers ─────────────────────────────────────────────────

  late Map<String, int> _idToIndex;
  late int _minIndex;
  late int _maxIndex;

  // ─ Slot state ────────────────────────────────────────────────────────────

  final ValueNotifier<ChapterLoadState> _prevSlot =
      ValueNotifier(const ChapterIdle());
  final ValueNotifier<ChapterLoadState> _centerSlot =
      ValueNotifier(const ChapterLoading());
  final ValueNotifier<ChapterLoadState> _nextSlot =
      ValueNotifier(const ChapterIdle());

  /// Current center chapter ID.
  late String _centerChapterId;

  /// Cached paragraphs keyed by chapter ID (LRU, max [_maxCacheSize] entries).
  final Map<String, List<ParagraphContent>> _cache = {};
  static const _maxCacheSize = 5;

  /// Whether the initial center chapter has been loaded.
  bool _centerReady = false;

  /// Generation counter to cancel stale _initCenter calls.
  int _initGeneration = 0;

  /// Error from initial center load.
  Object? _centerError;
  String? _centerErrorMessage;

  // ─ Reader view key (for calling jumpTo) ──────────────────────────────────
  // Mutable callback set by reader views on mount, cleared on dispose.
  void Function(int paragraphIndex, double offset)? _onViewJump;

  // ─ Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _buildIndexes();
    _centerChapterId = widget.controller.pendingChapterId ??
        (widget.chapters.isNotEmpty ? widget.chapters.first.id : '');
    widget.controller.addListener(_onJumpCommand);
    _initCenter();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onJumpCommand);
    _prevSlot.dispose();
    _centerSlot.dispose();
    _nextSlot.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ChapterContentManager oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onJumpCommand);
      widget.controller.addListener(_onJumpCommand);
    }

    final sourceChanged = oldWidget.feedId != widget.feedId ||
        oldWidget.bookId != widget.bookId ||
        oldWidget.chapters != widget.chapters;

    if (sourceChanged) {
      _buildIndexes();
      _cache.clear();
      _centerReady = false;
      _centerError = null;
      _prevSlot.value = const ChapterIdle();
      _centerSlot.value = const ChapterLoading();
      _nextSlot.value = const ChapterIdle();
      _centerChapterId =
          widget.chapters.isNotEmpty ? widget.chapters.first.id : '';
      _initCenter();
      return;
    }

    // Mode change: preserve current position and rebuild
    if (oldWidget.mode != widget.mode) {
      _pendingJumpParagraph = _lastReportedParagraph;
      _pendingJumpOffset = _lastReportedOffset;
      _pendingFromEnd = false;
      _jumpGeneration++;
      setState(() {});
    }

    // Font/line-height change: force new view state so pages recompute
    if (oldWidget.fontScale != widget.fontScale ||
        oldWidget.lineHeight != widget.lineHeight) {
      _pendingJumpParagraph = _lastReportedParagraph;
      _pendingJumpOffset = 0;
      _pendingFromEnd = false;
      _jumpGeneration++;
      setState(() {});
    }
  }

  // ─ Index building ────────────────────────────────────────────────────────

  void _buildIndexes() {
    _idToIndex = {for (final c in widget.chapters) c.id: c.index};
    if (widget.chapters.isEmpty) {
      _minIndex = 0;
      _maxIndex = -1;
    } else {
      _minIndex = widget.chapters
          .map((c) => c.index)
          .reduce((a, b) => a < b ? a : b);
      _maxIndex = widget.chapters
          .map((c) => c.index)
          .reduce((a, b) => a > b ? a : b);
    }
  }

  int _globalIndex(String id) => _idToIndex[id] ?? -1;

  String? _chapterIdAt(int index) {
    for (final c in widget.chapters) {
      if (c.index == index) return c.id;
    }
    return null;
  }


  bool _isLast(String id) => _globalIndex(id) == _maxIndex;

  String? _prevId(String id) {
    final idx = _globalIndex(id);
    return idx > _minIndex ? _chapterIdAt(idx - 1) : null;
  }

  String? _nextId(String id) {
    final idx = _globalIndex(id);
    return idx < _maxIndex ? _chapterIdAt(idx + 1) : null;
  }

  // ─ Cache ───────────────────────────────────────────────────────────────────

  void _putCache(String chapterId, List<ParagraphContent> paragraphs) {
    _cache.remove(chapterId);
    _cache[chapterId] = paragraphs;
    if (_cache.length <= _maxCacheSize) return;

    final keep = <String>{
      _centerChapterId,
      if (_prevId(_centerChapterId) != null) _prevId(_centerChapterId)!,
      if (_nextId(_centerChapterId) != null) _nextId(_centerChapterId)!,
    };
    final keys = _cache.keys.toList();
    for (final k in keys) {
      if (_cache.length <= _maxCacheSize) break;
      if (!keep.contains(k)) _cache.remove(k);
    }
  }

  // ─ Fetching ──────────────────────────────────────────────────────────────

  Future<List<ParagraphContent>> _fetchChapter(String chapterId) async {
    if (_cache.containsKey(chapterId)) return _cache[chapterId]!;

    final paragraphs = await FeedService.instance
        .paragraphs(
          feedId: widget.feedId,
          bookId: widget.bookId,
          chapterId: chapterId,
        )
        .toList();

    _putCache(chapterId, paragraphs);
    return paragraphs;
  }

  // ─ Initial center load ───────────────────────────────────────────────────

  Future<void> _initCenter() async {
    if (_centerChapterId.isEmpty) {
      setState(() => _centerReady = true);
      return;
    }

    final gen = ++_initGeneration;
    _centerSlot.value = const ChapterLoading();

    try {
      final paragraphs = await _fetchChapter(_centerChapterId);
      if (!mounted || gen != _initGeneration) return;

      _centerSlot.value = ChapterLoaded(paragraphs);
      setState(() {
        _centerReady = true;
        _centerError = null;
        _centerErrorMessage = null;
      });

      // Reset pending values after build consumed them
      _pendingJumpParagraph = 0;
      _pendingJumpOffset = 0;
      _pendingFromEnd = false;

      // Preload adjacent
      _loadAdjacent(_centerChapterId);
    } catch (e) {
      if (!mounted || gen != _initGeneration) return;
      setState(() {
        _centerReady = true;
        _centerError = e;
        _centerErrorMessage = normalizeErrorMessage(e);
      });
    }
  }

  // ─ Adjacent loading (no setState!) ───────────────────────────────────────

  void _loadAdjacent(String centerId) {
    final prev = _prevId(centerId);
    final next = _nextId(centerId);

    if (prev != null) _loadSlot(prev, _prevSlot);
    if (next != null) _loadSlot(next, _nextSlot);
  }

  Future<void> _loadSlot(
      String chapterId, ValueNotifier<ChapterLoadState> slot) async {
    if (_cache.containsKey(chapterId)) {
      slot.value = ChapterLoaded(_cache[chapterId]!);
      return;
    }

    slot.value = const ChapterLoading();

    try {
      final paragraphs = await _fetchChapter(chapterId);
      if (!mounted) return;
      slot.value = ChapterLoaded(paragraphs);
    } catch (e) {
      if (!mounted) return;
      slot.value = ChapterLoadError(
        error: e,
        message: normalizeErrorMessage(e),
      );
    }
  }

  // ─ Chapter boundary callback from reader views ───────────────────────────

  void _onChapterBoundary(ChapterDirection direction) {
    final newCenterId = direction == ChapterDirection.next
        ? _nextId(_centerChapterId)
        : _prevId(_centerChapterId);

    if (newCenterId == null) return;

    // If the target chapter isn't loaded yet, load it first then slide.
    // This prevents a flash of empty content on the new view.
    if (!_cache.containsKey(newCenterId)) {
      _fetchChapter(newCenterId).then((_) {
        if (!mounted) return;
        // Only slide if we're still on the same center (user didn't jump)
        final stillOnSameCenter = direction == ChapterDirection.next
            ? _nextId(_centerChapterId) == newCenterId
            : _prevId(_centerChapterId) == newCenterId;
        if (stillOnSameCenter) _performSlide(direction, newCenterId);
      }).catchError((_) {
        // Error already surfaces via the sentinel's error state
      });
      return;
    }

    _performSlide(direction, newCenterId);
  }

  void _performSlide(ChapterDirection direction, String newCenterId) {
    // Report position to parent
    widget.controller.reportPosition(
      chapterId: newCenterId,
      paragraphIndex: 0,
    );

    _centerChapterId = newCenterId;
    _pendingFromEnd = direction == ChapterDirection.previous;

    final prev = _prevId(newCenterId);
    final next = _nextId(newCenterId);

    // Update ValueNotifiers (target must be cached here)
    _centerSlot.value = ChapterLoaded(_cache[newCenterId]!);
    if (prev != null && _cache.containsKey(prev)) {
      _prevSlot.value = ChapterLoaded(_cache[prev]!);
    } else {
      _prevSlot.value = const ChapterIdle();
    }
    if (next != null && _cache.containsKey(next)) {
      _nextSlot.value = ChapterLoaded(_cache[next]!);
    } else {
      _nextSlot.value = const ChapterIdle();
    }

    // Boundary fires on ScrollEndNotification: animation already settled.
    // Rebuild without bumping _jumpGeneration so the view updates in place
    // via didUpdateWidget (no State recreation, no input-blocking gap).
    setState(() {});
    _loadAdjacent(newCenterId);
  }

  // ─ Position update callback from reader views ────────────────────────────

  int _lastReportedParagraph = 0;
  double _lastReportedOffset = 0;

  void _onPositionUpdate(String chapterId, int paragraphIndex, double offset) {
    _lastReportedParagraph = paragraphIndex;
    _lastReportedOffset = offset;
    widget.controller.reportPosition(
      chapterId: chapterId,
      paragraphIndex: paragraphIndex,
      offset: offset,
    );
  }

  // ─ Retry callback ───────────────────────────────────────────────────────

  void _onRetry(String chapterId) {
    _cache.remove(chapterId);

    if (chapterId == _centerChapterId) {
      // Retry center: show loading overlay again
      setState(() {
        _centerReady = false;
        _centerError = null;
        _centerErrorMessage = null;
      });
      _initCenter();
      return;
    }

    // Retry adjacent
    final prev = _prevId(_centerChapterId);
    final next = _nextId(_centerChapterId);

    if (chapterId == prev) {
      _loadSlot(chapterId, _prevSlot);
    } else if (chapterId == next) {
      _loadSlot(chapterId, _nextSlot);
    }
  }

  // ─ Jump command from controller ──────────────────────────────────────────

  int _pendingJumpParagraph = 0;
  double _pendingJumpOffset = 0;
  bool _pendingFromEnd = false;
  int _jumpGeneration = 0;

  void _onJumpCommand() {
    final targetId = widget.controller.pendingChapterId;
    if (targetId == null) return;

    final paragraphIndex = widget.controller.pendingParagraphIndex;
    final offset = widget.controller.pendingOffset;
    widget.controller.consumeJump();

    if (targetId == _centerChapterId) {
      _onViewJump?.call(paragraphIndex, offset);
      return;
    }

    // Different chapter: re-center the window
    _centerChapterId = targetId;
    _pendingJumpParagraph = paragraphIndex;
    _pendingJumpOffset = offset;
    _pendingFromEnd = false;
    _centerError = null;
    _centerErrorMessage = null;

    widget.controller.reportPosition(
      chapterId: targetId,
      paragraphIndex: paragraphIndex,
      offset: offset,
    );

    // Fast path: if the target is already cached, populate slots
    // synchronously and skip _jumpGeneration bump so the view updates
    // in place via didUpdateWidget (uses pages cache, no heavy recompute).
    if (_cache.containsKey(targetId)) {
      final prev = _prevId(targetId);
      final next = _nextId(targetId);
      _centerSlot.value = ChapterLoaded(_cache[targetId]!);
      _prevSlot.value = prev != null && _cache.containsKey(prev)
          ? ChapterLoaded(_cache[prev]!)
          : const ChapterIdle();
      _nextSlot.value = next != null && _cache.containsKey(next)
          ? ChapterLoaded(_cache[next]!)
          : const ChapterIdle();
      _centerReady = true;
      setState(() {});
      _loadAdjacent(targetId);
    } else {
      // Slow path: need to fetch from network. Bump generation to
      // create a fresh view after loading completes.
      _jumpGeneration++;
      _centerReady = false;
      _prevSlot.value = const ChapterIdle();
      _centerSlot.value = const ChapterLoading();
      _nextSlot.value = const ChapterIdle();
      setState(() {});
      _initCenter();
    }
  }

  // ─ Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Loading overlay for center chapter
    if (!_centerReady) {
      return const Center(child: CircularProgressIndicator());
    }

    // Error for center chapter initial load
    if (_centerError != null) {
      return Center(
        child: ChapterStatusBlock(
          kind: ChapterStatusBlockKind.error,
          message: _centerErrorMessage,
          onRetry: () => _onRetry(_centerChapterId),
        ),
      );
    }

    if (_centerChapterId.isEmpty) {
      return const SizedBox.shrink();
    }

    final prev = _prevId(_centerChapterId);
    final next = _nextId(_centerChapterId);
    final isLast = _isLast(_centerChapterId);
    final initialParagraph = _pendingJumpParagraph;
    final initialOffset = _pendingJumpOffset;
    final initialFromEnd = _pendingFromEnd;

    if (widget.mode == ReaderMode.verticalScroll) {
      return VerticalReaderView(
        key: ValueKey('v-$_jumpGeneration'),
        prevSlot: _prevSlot,
        centerSlot: _centerSlot,
        nextSlot: _nextSlot,
        centerChapterId: _centerChapterId,
        prevChapterId: prev,
        nextChapterId: next,
        isLastChapter: isLast,
        fontScale: widget.fontScale,
        lineHeight: widget.lineHeight,
        contentPadding: widget.contentPadding,
        onChapterBoundary: _onChapterBoundary,
        onPositionUpdate: _onPositionUpdate,
        onRetry: _onRetry,
        initialParagraphIndex: initialParagraph,
        initialOffset: initialOffset,
        onJumpRegistered: (fn) => _onViewJump = fn,
        onParagraphLongPress: widget.onParagraphLongPress,
      );
    }

    return HorizontalReaderView(
      key: ValueKey('h-$_jumpGeneration'),
      prevSlot: _prevSlot,
      centerSlot: _centerSlot,
      nextSlot: _nextSlot,
      centerChapterId: _centerChapterId,
      prevChapterId: prev,
      nextChapterId: next,
      isLastChapter: isLast,
      fontScale: widget.fontScale,
      lineHeight: widget.lineHeight,
      contentPadding: widget.contentPadding,
      onChapterBoundary: _onChapterBoundary,
      onPositionUpdate: _onPositionUpdate,
      onRetry: _onRetry,
      initialParagraphIndex: initialParagraph,
      initialFromEnd: initialFromEnd,
      onJumpRegistered: (fn) => _onViewJump = fn,
      onParagraphLongPress: widget.onParagraphLongPress,
    );
  }
}

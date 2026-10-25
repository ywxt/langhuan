import 'dart:async';

import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/loading.dart';
import '../../../src/rust/api/types.dart';
import '../../feeds/feed_service.dart';
import '../reader_settings_provider.dart' show ReaderPageMode;
import 'horizontal_reader_view.dart';
import 'page_breaker.dart';
import 'reader_chapter_window.dart';
import 'reader_controller.dart';
import 'reader_types.dart';
import 'seamless_vertical_reader.dart';

/// Wires the shared [ReaderChapterWindow] into the active reader view.
///
/// * **Vertical** mode renders [SeamlessVerticalReader] — seamless scroll
///   across chapter boundaries.
/// * **Horizontal** mode concatenates the window chapters' pages into one
///   flat, cross-chapter page list; [HorizontalReaderView] walks it by
///   index, so turning past a chapter boundary is just an index change.
///
/// The canonical horizontal position is `(chapterId, localPageIndex)` and is
/// re-resolved against the flat list on every rebuild, which makes it immune
/// to entries being added/removed by window expansion, trimming or reloads.
class ChapterContentManager extends StatefulWidget {
  const ChapterContentManager({
    super.key,
    required this.feedId,
    required this.bookId,
    required this.chapters,
    required this.controller,
    required this.pageMode,
    required this.onToggleControls,
    required this.fontScale,
    this.fontFamily,
    this.letterSpacing = 0.0,
    this.paragraphSpacing = LanghuanTheme.spaceMd,
    required this.lineHeight,
    required this.contentPadding,
    required this.chineseConversion,
    this.onParagraphLongPress,
    this.selectedChapterId,
    this.selectedParagraphId,
  });

  final String feedId;
  final String bookId;
  final List<ChapterInfoModel> chapters;
  final ReaderController controller;
  final ReaderPageMode pageMode;
  final VoidCallback onToggleControls;
  final double fontScale;
  final String? fontFamily;
  final double letterSpacing;
  final double paragraphSpacing;
  final double lineHeight;
  final EdgeInsets contentPadding;
  final ChineseConversionMode chineseConversion;
  final void Function(
    String chapterId,
    String paragraphId,
    ParagraphContent paragraph,
    Rect globalRect,
  )?
  onParagraphLongPress;
  final String? selectedChapterId;
  final String? selectedParagraphId;

  @override
  State<ChapterContentManager> createState() => _ChapterContentManagerState();
}

/// One entry of the flat horizontal page list.
class _FlatEntry {
  const _FlatEntry({
    required this.chapterId,
    required this.localPageIndex,
    required this.loading,
    this.errorMessage,
  });

  final String chapterId;

  /// Index of the page within its chapter, or -1 for a placeholder entry
  /// (neighbor chapter still loading / failed).
  final int localPageIndex;
  final bool loading;
  final String? errorMessage;
}

class _ChapterContentManagerState extends State<ChapterContentManager> {
  ReaderChapterWindow? _window;

  PageBreaker? _breaker;
  Size _lastPageSize = Size.zero;
  final Map<String, List<PageContent>> _pagesByChapter = {};

  // Canonical horizontal position.
  String _activeChapterId = '';
  int _activeLocalPageIndex = 0;
  String _pendingJumpParagraphId = '';
  int _pendingJumpCharOffset = 0;

  // Vertical scroll target (token distinguishes consecutive commands).
  int _scrollToken = 0;
  ReaderScrollTarget? _verticalTarget;

  String _lastReportedChapterId = '';
  String _lastReportedParagraphId = '';
  int _lastReportedCharOffset = 0;

  @override
  void initState() {
    super.initState();

    final startId =
        widget.controller.pendingChapterId ??
        (widget.chapters.isNotEmpty ? widget.chapters.first.id : '');
    final pendingParagraphId = widget.controller.pendingParagraphId;
    final pendingCharOffset = widget.controller.pendingCharOffset;
    widget.controller.consumeJump();
    widget.controller.addListener(_onControllerCommand);

    _activeChapterId = startId;
    _pendingJumpParagraphId = pendingParagraphId;
    _pendingJumpCharOffset = pendingCharOffset;
    _verticalTarget = ReaderScrollTarget(
      token: ++_scrollToken,
      chapterId: startId,
      paragraphId: pendingParagraphId,
    );

    _window = ReaderChapterWindow(
      chapters: widget.chapters,
      anchorChapterId: startId,
      loader: _loadChapterParagraphs,
    );
    _window!.addListener(_onWindowChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerCommand);
    _window?.removeListener(_onWindowChanged);
    _window?.dispose();
    super.dispose();
  }

  Future<List<ParagraphContent>> _loadChapterParagraphs(
    String chapterId, {
    bool forceRefresh = false,
  }) {
    return FeedService.instance
        .paragraphs(
          feedId: widget.feedId,
          bookId: widget.bookId,
          chapterId: chapterId,
          forceRefresh: forceRefresh,
        )
        .toList();
  }

  // ── Controller commands ─────────────────────────────────────────────────

  void _onControllerCommand() {
    final reloadId = widget.controller.consumeChapterReload();
    if (reloadId != null && reloadId.isNotEmpty) {
      _onChapterReloadCommand(reloadId);
    }

    final targetId = widget.controller.pendingChapterId;
    if (targetId == null) return;
    final paragraphId = widget.controller.pendingParagraphId;
    final charOffset = widget.controller.pendingCharOffset;
    widget.controller.consumeJump();
    _onJumpCommand(targetId, paragraphId, charOffset);
  }

  void _onJumpCommand(String chapterId, String paragraphId, int charOffset) {
    _activeChapterId = chapterId;
    _activeLocalPageIndex = 0;
    _pendingJumpParagraphId = paragraphId;
    _pendingJumpCharOffset = charOffset;
    _verticalTarget = ReaderScrollTarget(
      token: ++_scrollToken,
      chapterId: chapterId,
      paragraphId: paragraphId,
    );

    _window!.jumpTo(chapterId);
    _reportPosition(chapterId, paragraphId, 0, charOffset);

    _resolveHorizontalPendingJump();
    setState(() {});
  }

  void _onChapterReloadCommand(String chapterId) {
    _pagesByChapter.remove(chapterId);
    unawaited(_window!.reload(chapterId));
  }

  // ── Window bookkeeping ──────────────────────────────────────────────────

  void _onWindowChanged() {
    _resolveHorizontalPendingJump();
    if (widget.pageMode == ReaderPageMode.horizontal) {
      _preloadWindowEdgesForHorizontal();
    }
    if (mounted) setState(() {});
  }

  void _resolveHorizontalPendingJump() {
    if (widget.pageMode != ReaderPageMode.horizontal) return;
    if (_pendingJumpParagraphId.isEmpty) return;
    if (_activeChapterId.isEmpty) return;
    final pages = _pagesFor(_activeChapterId);
    if (pages.isEmpty) return;
    _activeLocalPageIndex = PageBreaker.pageForPosition(
      pages,
      _pendingJumpParagraphId,
      _pendingJumpCharOffset,
    ).clamp(0, pages.length - 1);
    _pendingJumpParagraphId = '';
    _pendingJumpCharOffset = 0;
  }

  /// Keep a couple of pages of runway at both ends of the flat list so page
  /// turns never run into a hard edge while more content exists.
  void _preloadWindowEdgesForHorizontal() {
    final window = _window!;
    final entries = _buildFlatEntries();
    final abs = _resolveActiveAbsoluteIndex(entries);
    if (abs < 0) return;
    if (abs <= 2 && window.hasChapterAbove) window.expandAbove();
    if (abs >= entries.length - 3 && window.hasChapterBelow) {
      window.expandBelow();
    }
  }

  // ── Page computation ────────────────────────────────────────────────────

  void _ensureBreaker() {
    final size = MediaQuery.sizeOf(context);
    final pageSize = Size(
      size.width - widget.contentPadding.horizontal,
      size.height - widget.contentPadding.vertical,
    );
    if (_breaker != null && _lastPageSize == pageSize) return;
    _lastPageSize = pageSize;
    _breaker = _createBreaker(context);
  }

  PageBreaker _createBreaker(BuildContext context) {
    final theme = Theme.of(context);
    final bodyLarge = theme.textTheme.bodyLarge?.copyWith(
      fontSize: (theme.textTheme.bodyLarge?.fontSize ?? 16) * widget.fontScale,
      fontFamily: widget.fontFamily,
      letterSpacing: widget.letterSpacing,
      height: widget.lineHeight,
    );
    final headlineSmall = theme.textTheme.headlineSmall?.copyWith(
      fontSize:
          (theme.textTheme.headlineSmall?.fontSize ?? 24) * widget.fontScale,
      fontFamily: widget.fontFamily,
      letterSpacing: widget.letterSpacing,
    );
    final size = MediaQuery.sizeOf(context);
    final pageSize = Size(
      size.width - widget.contentPadding.horizontal,
      size.height - widget.contentPadding.vertical,
    );
    return PageBreaker(
      pageSize: pageSize,
      textStyle: bodyLarge ?? const TextStyle(),
      titleStyle: headlineSmall ?? const TextStyle(),
      paragraphSpacing: widget.paragraphSpacing,
      imageHeight: pageSize.width * 9 / 16,
      textDirection: Directionality.of(context),
    );
  }

  List<PageContent> _pagesFor(String chapterId) {
    final cached = _pagesByChapter[chapterId];
    if (cached != null) return cached;
    final breaker = _breaker;
    if (breaker == null) return const [];
    final paragraphs = _window!.paragraphsOf(chapterId);
    if (paragraphs == null || paragraphs.isEmpty) return const [];
    final pages = breaker.computePages(paragraphs, chapterId: chapterId);
    _pagesByChapter[chapterId] = pages;
    return pages;
  }

  double? _estimateParagraphOffset(String chapterId, String paragraphId) {
    final pages = _pagesFor(chapterId);
    if (pages.isEmpty) return null;
    final idx = PageBreaker.pageForParagraph(pages, paragraphId);
    if (idx <= 0) return 0;
    return idx * (_breaker?.pageSize.height ?? 0);
  }

  // ── Flat page list (horizontal) ─────────────────────────────────────────

  List<_FlatEntry> _buildFlatEntries() {
    final window = _window!;
    final entries = <_FlatEntry>[];
    for (final chapterId in window.windowChapterIds) {
      final state = window.stateOf(chapterId);
      if (state is ChapterLoaded) {
        if (state.paragraphs.isEmpty) continue;
        final pages = _pagesFor(chapterId);
        for (var i = 0; i < pages.length; i++) {
          entries.add(
            _FlatEntry(chapterId: chapterId, localPageIndex: i, loading: false),
          );
        }
      } else if (state is ChapterLoadError) {
        entries.add(
          _FlatEntry(
            chapterId: chapterId,
            localPageIndex: -1,
            loading: false,
            errorMessage: state.message,
          ),
        );
      } else if (state is ChapterLoading) {
        entries.add(
          _FlatEntry(chapterId: chapterId, localPageIndex: -1, loading: true),
        );
      }
    }
    return entries;
  }

  int _resolveActiveAbsoluteIndex(List<_FlatEntry> entries) {
    if (entries.isEmpty) return -1;

    var sameChapterFirst = -1;
    var anchorFirst = -1;
    final anchorId = _window!.anchorChapterId;

    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (entry.chapterId == _activeChapterId &&
          entry.localPageIndex == _activeLocalPageIndex) {
        return i;
      }
      if (entry.chapterId == _activeChapterId && sameChapterFirst < 0) {
        sameChapterFirst = i;
      }
      if (entry.chapterId == anchorId && anchorFirst < 0) {
        anchorFirst = i;
      }
    }

    if (sameChapterFirst >= 0) {
      // Page count shrank (reload) — clamp to the chapter's last page.
      var last = sameChapterFirst;
      for (
        var i = sameChapterFirst + 1;
        i < entries.length && entries[i].chapterId == _activeChapterId;
        i++
      ) {
        last = i;
      }
      return last;
    }
    if (anchorFirst >= 0) return anchorFirst;
    return 0;
  }

  ReaderSlot _slotFor(_FlatEntry entry) {
    final chapterTitle = _chapterTitleOf(entry.chapterId);
    if (entry.loading) {
      return ReaderSlotLoading(entry.chapterId, chapterTitle: chapterTitle);
    }
    if (entry.errorMessage != null) {
      return ReaderSlotError(
        chapterId: entry.chapterId,
        chapterTitle: chapterTitle,
        message: entry.errorMessage!,
      );
    }
    final pages = _pagesFor(entry.chapterId);
    final page = entry.localPageIndex < pages.length
        ? pages[entry.localPageIndex]
        : null;
    if (page == null) {
      return ReaderSlotLoading(entry.chapterId, chapterTitle: chapterTitle);
    }
    return ReaderSlotPage(page);
  }

  String? _chapterTitleOf(String chapterId) {
    for (final chapter in widget.chapters) {
      if (chapter.id == chapterId) return chapter.title;
    }
    return null;
  }

  // ── Page turns (horizontal) ─────────────────────────────────────────────

  void _applyActiveEntry(_FlatEntry entry) {
    _activeChapterId = entry.chapterId;
    _activeLocalPageIndex = entry.localPageIndex;
    _pendingJumpParagraphId = '';
  }

  void _onHorizontalNextPage() {
    final entries = _buildFlatEntries();
    final abs = _resolveActiveAbsoluteIndex(entries);
    if (abs < 0) return;
    if (abs < entries.length - 1) {
      _applyActiveEntry(entries[abs + 1]);
      _reportCurrentHorizontalPosition();
    }
    _preloadWindowEdgesForHorizontal();
    _window!.maintainAround(_activeChapterId);
    setState(() {});
  }

  void _onHorizontalPrevPage() {
    final entries = _buildFlatEntries();
    final abs = _resolveActiveAbsoluteIndex(entries);
    if (abs < 0) return;
    if (abs > 0) {
      _applyActiveEntry(entries[abs - 1]);
      _reportCurrentHorizontalPosition();
    }
    _preloadWindowEdgesForHorizontal();
    _window!.maintainAround(_activeChapterId);
    setState(() {});
  }

  void _reportCurrentHorizontalPosition() {
    var paragraphId = '';
    var charOffset = 0;
    if (_activeLocalPageIndex >= 0) {
      final pages = _pagesFor(_activeChapterId);
      if (_activeLocalPageIndex < pages.length) {
        final page = pages[_activeLocalPageIndex];
        paragraphId = page.firstParagraphId;
        charOffset = page.firstCharOffset;
      }
    }
    _reportPosition(_activeChapterId, paragraphId, 0, charOffset);
  }

  // ── Position reporting ──────────────────────────────────────────────────

  void _reportPosition(
    String chapterId,
    String paragraphId,
    double offset, [
    int charOffset = 0,
  ]) {
    _lastReportedChapterId = chapterId;
    _lastReportedParagraphId = paragraphId;
    _lastReportedCharOffset = charOffset;
    widget.controller.reportPosition(
      chapterId: chapterId,
      paragraphId: paragraphId,
      paragraphOffset: offset,
      charOffset: charOffset,
    );
  }

  // ── Widget updates ──────────────────────────────────────────────────────

  @override
  void didUpdateWidget(covariant ChapterContentManager oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerCommand);
      widget.controller.addListener(_onControllerCommand);
    }

    final sourceChanged =
        oldWidget.feedId != widget.feedId ||
        oldWidget.bookId != widget.bookId ||
        oldWidget.chapters != widget.chapters;

    if (sourceChanged) {
      final anchorId =
          _activeChapterId.isNotEmpty &&
              widget.chapters.any((c) => c.id == _activeChapterId)
          ? _activeChapterId
          : (widget.chapters.isNotEmpty ? widget.chapters.first.id : '');
      _pagesByChapter.clear();
      _activeChapterId = anchorId;
      _activeLocalPageIndex = 0;
      _window!.setChapters(widget.chapters, anchorId);
      _verticalTarget = ReaderScrollTarget(
        token: ++_scrollToken,
        chapterId: anchorId,
      );
      setState(() {});
      return;
    }

    if (oldWidget.chineseConversion != widget.chineseConversion) {
      // Paragraphs must be re-fetched through the new conversion mode.
      _pagesByChapter.clear();
      _window!.reloadWindow();
      _restorePositionAfterReflow();
      return;
    }

    final typographyChanged =
        oldWidget.fontScale != widget.fontScale ||
        oldWidget.fontFamily != widget.fontFamily ||
        oldWidget.letterSpacing != widget.letterSpacing ||
        oldWidget.paragraphSpacing != widget.paragraphSpacing ||
        oldWidget.lineHeight != widget.lineHeight;

    if (typographyChanged) {
      // Pages are stale but paragraphs are not — recompute lazily.
      _pagesByChapter.clear();
      _breaker = null;
      _lastPageSize = Size.zero;
      _restorePositionAfterReflow();
      return;
    }

    if (oldWidget.pageMode != widget.pageMode) {
      _switchMode(oldWidget.pageMode, widget.pageMode);
    }
  }

  /// Re-resolve the saved position after content re-flowed (settings or
  /// conversion change).
  void _restorePositionAfterReflow() {
    final chapterId = _lastReportedChapterId.isNotEmpty
        ? _lastReportedChapterId
        : _activeChapterId;
    final paragraphId = _lastReportedParagraphId;
    final charOffset = _lastReportedCharOffset;
    _activeChapterId = chapterId;
    _pendingJumpParagraphId = paragraphId;
    _pendingJumpCharOffset = charOffset;
    _verticalTarget = ReaderScrollTarget(
      token: ++_scrollToken,
      chapterId: chapterId,
      paragraphId: paragraphId,
    );
    _ensureBreaker();
    _resolveHorizontalPendingJump();
    setState(() {});
  }

  void _switchMode(ReaderPageMode oldMode, ReaderPageMode newMode) {
    final chapterId = _lastReportedChapterId.isNotEmpty
        ? _lastReportedChapterId
        : _activeChapterId;
    _activeChapterId = chapterId;

    // If the window drifted away from the position (possible after long
    // vertical runs), re-anchor around it.
    if (!_window!.windowChapterIds.contains(chapterId)) {
      _window!.jumpTo(chapterId);
    }

    if (newMode == ReaderPageMode.vertical) {
      _verticalTarget = ReaderScrollTarget(
        token: ++_scrollToken,
        chapterId: chapterId,
        paragraphId: _lastReportedParagraphId,
      );
    } else {
      // Switching into paged mode: the last reported char offset anchors the
      // target page (0 when coming from vertical mode, which does not track
      // character positions).
      _pendingJumpParagraphId = _lastReportedParagraphId;
      _pendingJumpCharOffset = _lastReportedCharOffset;
      _ensureBreaker();
      _resolveHorizontalPendingJump();
    }
    setState(() {});
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final window = _window;
    if (window == null || widget.chapters.isEmpty) {
      return const SizedBox.shrink();
    }

    if (widget.pageMode == ReaderPageMode.vertical) {
      return SeamlessVerticalReader(
        window: window,
        chapters: widget.chapters,
        contentPadding: widget.contentPadding,
        fontScale: widget.fontScale,
        fontFamily: widget.fontFamily,
        letterSpacing: widget.letterSpacing,
        paragraphSpacing: widget.paragraphSpacing,
        lineHeight: widget.lineHeight,
        onPositionChanged: _reportPosition,
        onToggleControls: widget.onToggleControls,
        onParagraphLongPress: widget.onParagraphLongPress,
        selectedChapterId: widget.selectedChapterId,
        selectedParagraphId: widget.selectedParagraphId,
        scrollTarget: _verticalTarget,
        estimateParagraphOffset: _estimateParagraphOffset,
      );
    }

    _ensureBreaker();
    final entries = _buildFlatEntries();
    if (entries.isEmpty) {
      return const LoadingState();
    }

    final abs = _resolveActiveAbsoluteIndex(entries);
    final current = _slotFor(entries[abs]);
    final prev = abs > 0 ? _slotFor(entries[abs - 1]) : null;
    final next = abs < entries.length - 1 ? _slotFor(entries[abs + 1]) : null;

    return HorizontalReaderView(
      currentSlot: current,
      prevSlot: prev,
      nextSlot: next,
      isFirstPage: abs == 0 && !window.hasChapterAbove,
      isLastPage: abs == entries.length - 1 && !window.hasChapterBelow,
      fontScale: widget.fontScale,
      fontFamily: widget.fontFamily,
      letterSpacing: widget.letterSpacing,
      paragraphSpacing: widget.paragraphSpacing,
      lineHeight: widget.lineHeight,
      contentPadding: widget.contentPadding,
      onNextPage: _onHorizontalNextPage,
      onPrevPage: _onHorizontalPrevPage,
      onToggleControls: widget.onToggleControls,
      onRetryChapter: (chapterId) => window.retry(chapterId),
      onParagraphLongPress: widget.onParagraphLongPress,
      selectedChapterId: widget.selectedChapterId,
      selectedParagraphId: widget.selectedParagraphId,
    );
  }
}

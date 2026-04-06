import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../src/bindings/signals/signals.dart';
import 'chapter_loader.dart';
import 'chapter_status_block.dart';
import 'page_breaker.dart';
import 'page_content_view.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Flat-list horizontal reader
//
// Design: Build a flat list of _FlatPage entries from all loaded slots.
// Each slot contributes N content pages (if ready), or 1 loading/error page.
// If isAtBookEnd, an endOfBook page is appended.
//
// The PageView uses itemCount = flat list length, so Flutter naturally
// prevents swiping past the first or last page.
//
// When slots change (background load, error, etc.), the flat list is
// rebuilt and mapped by stable page keys, so the visible page remains
// stable across child reordering (loading -> content, error -> content).
// The PageController is created once and never replaced.
// ─────────────────────────────────────────────────────────────────────────────

/// Half of the virtual page range — kept for test compatibility.
const int kVirtualHalfRange = 500000;

// ── Flat page model ─────────────────────────────────────────────────────

enum _FlatPageKind { content, loading, error, endOfBook }

class _FlatPage {
  final _FlatPageKind kind;
  final String? chapterId;
  final PageContent? page;
  final int pageIndexInChapter; // for content pages
  final String? errorMessage;

  const _FlatPage({
    required this.kind,
    this.chapterId,
    this.page,
    this.pageIndexInChapter = 0,
    this.errorMessage,
  });
}

// ─────────────────────────────────────────────────────────────────────────────

class HorizontalReaderView extends StatefulWidget {
  const HorizontalReaderView({
    super.key,
    required this.loader,
    required this.initialChapterId,
    required this.initialParagraphIndex,
    required this.contentPadding,
    required this.onChapterChanged,
    required this.onParagraphChanged,
  });

  final ChapterLoader loader;
  final String initialChapterId;
  final int initialParagraphIndex;
  final EdgeInsets contentPadding;
  final ValueChanged<String> onChapterChanged;
  final ValueChanged<int> onParagraphChanged;

  @override
  State<HorizontalReaderView> createState() => _HorizontalReaderViewState();
}

class _HorizontalReaderViewState extends State<HorizontalReaderView> {
  // ── Page controller — created once, never replaced ─────────────────────
  PageController? _pageController;

  // ── Page breaker ───────────────────────────────────────────────────────
  Size _pageSize = Size.zero;
  PageBreaker? _pageBreaker;

  // ── Computed pages cache (keyed by chapterId) ─────────────────────────
  final Map<String, List<PageContent>> _pagesCache = {};

  // ── 3-chapter window identities ───────────────────────────────────────
  // _windowChapterId is the chapter used as the centre of the flat list.
  // It is frozen while a scroll gesture is active so the list never shifts
  // under-the-finger; it advances to _currentChapterId once the scroll
  // fully settles.
  String? _windowChapterId;
  String? _prevChapterId;
  String? _nextChapterId;

  // ── Flat page list ────────────────────────────────────────────────────
  List<_FlatPage> _flatPages = const [];
  final Map<String, int> _flatIndexByKey = {};

  // ── Current logical position ──────────────────────────────────────────
  late String _currentChapterId;
  int _currentPageInChapter = 0;
  int _currentFlatIndex = 0;
  String? _currentPageKey;
  bool _isOnEndOfBook = false;

  // ── Callback tracking ─────────────────────────────────────────────────
  String? _visibleChapterId;
  int _lastReportedParagraphIndex = 0;

  // ── Flags ─────────────────────────────────────────────────────────────
  bool _initialJumpDone = false;
  bool _suppressPageChanged = false;
  bool _isScrolling = false;
  bool _deferAnchorCorrection = false;

  @override
  void initState() {
    super.initState();
    _currentChapterId = widget.initialChapterId;
    _windowChapterId = widget.initialChapterId;
    widget.loader.addListener(_onLoaderChanged);
  }

  @override
  void dispose() {
    widget.loader.removeListener(_onLoaderChanged);
    _detachScrollingListener();
    _pageController?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(HorizontalReaderView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.loader != widget.loader) {
      oldWidget.loader.removeListener(_onLoaderChanged);
      widget.loader.addListener(_onLoaderChanged);
      _pagesCache.clear();
    }
  }

  void _onLoaderChanged() {
    final slots = widget.loader.slots;
    final slotIds = <String>{};
    for (final s in slots) {
      slotIds.add(s.chapterId);
      if (!s.isReady) {
        _pagesCache.remove(s.chapterId);
      }
    }
    _pagesCache.removeWhere((id, _) => !slotIds.contains(id));
    if (mounted) setState(() {});
  }

  // ── Page breaker initialisation ────────────────────────────────────────

  void _ensurePageBreaker(Size size) {
    if (_pageBreaker != null && _pageSize == size) return;
    _pageSize = size;
    _pagesCache.clear();

    final theme = Theme.of(context);
    final bodyLarge = theme.textTheme.bodyLarge?.copyWith(height: 1.8) ??
        const TextStyle(fontSize: 16, height: 1.8);
    final headlineSmall =
        theme.textTheme.headlineSmall ?? const TextStyle(fontSize: 24);

    _pageBreaker = PageBreaker(
      pageSize: size,
      textStyle: bodyLarge,
      titleStyle: headlineSmall,
      paragraphSpacing: LanghuanTheme.spaceMd,
      imageHeight: size.width * 9 / 16,
      textDirection: Directionality.of(context),
    );
  }

  // ── Get pages for a chapter (cached) ──────────────────────────────────

  List<PageContent> _getPages(String chapterId) {
    final cached = _pagesCache[chapterId];
    if (cached != null) return cached;

    final slot = widget.loader.getSlot(chapterId);
    if (slot == null || !slot.isReady || _pageBreaker == null) return const [];

    final paragraphs = slot.paragraphs;
    if (paragraphs == null || paragraphs.isEmpty) return const [];

    final pages = _pageBreaker!.computePages(paragraphs);
    _pagesCache[chapterId] = pages;
    return pages;
  }

  void _updateWindowChapterIds() {
    // Advance the window centre only when no scroll is in progress.
    // This keeps the flat list stable while the user drags across a chapter
    // boundary; _onScrollingChanged will advance it once the scroll settles.
    if (!_isScrolling) {
      _windowChapterId = _currentChapterId;
    }

    final chapters = widget.loader.chapters;
    final centerId = _windowChapterId ?? _currentChapterId;
    final currentIdx = chapters.indexWhere((c) => c.id == centerId);
    if (currentIdx < 0) {
      _prevChapterId = null;
      _nextChapterId = null;
      return;
    }

    _prevChapterId = currentIdx > 0 ? chapters[currentIdx - 1].id : null;
    _nextChapterId =
        currentIdx < chapters.length - 1 ? chapters[currentIdx + 1].id : null;
  }

  List<_FlatPage> _buildPagesForChapter(String chapterId) {
    final slot = widget.loader.getSlot(chapterId);
    if (slot == null) {
      return [
        _FlatPage(kind: _FlatPageKind.loading, chapterId: chapterId),
      ];
    }

    if (slot.isReady) {
      final chapterPages = _getPages(chapterId);
      if (chapterPages.isEmpty) {
        return [
          _FlatPage(kind: _FlatPageKind.loading, chapterId: chapterId),
        ];
      }
      return [
        for (int i = 0; i < chapterPages.length; i++)
          _FlatPage(
            kind: _FlatPageKind.content,
            chapterId: chapterId,
            page: chapterPages[i],
            pageIndexInChapter: i,
          ),
      ];
    }

    if (slot.isError) {
      return [
        _FlatPage(
          kind: _FlatPageKind.error,
          chapterId: chapterId,
          errorMessage: slot.errorMessage,
        ),
      ];
    }

    return [
      _FlatPage(kind: _FlatPageKind.loading, chapterId: chapterId),
    ];
  }

  // ── Build flat page list ──────────────────────────────────────────────

  List<_FlatPage> _buildFlatPages() {
    _updateWindowChapterIds();
    final pages = <_FlatPage>[];

    _appendChapterPages(pages, _prevChapterId);
    _appendChapterPages(pages, _currentChapterId);
    _appendChapterPages(pages, _nextChapterId);

    // End of book indicator.
    if (widget.loader.isAtBookEnd && _nextChapterId == null && pages.isNotEmpty) {
      pages.add(const _FlatPage(kind: _FlatPageKind.endOfBook));
    }

    return pages;
  }

  void _appendChapterPages(List<_FlatPage> pages, String? chapterId) {
    if (chapterId == null) return;
    pages.addAll(_buildPagesForChapter(chapterId));
  }

  String _flatPageKey(_FlatPage page) {
    switch (page.kind) {
      case _FlatPageKind.content:
        return 'content:${page.chapterId}:${page.pageIndexInChapter}';
      case _FlatPageKind.loading:
        return 'loading:${page.chapterId}';
      case _FlatPageKind.error:
        return 'error:${page.chapterId}';
      case _FlatPageKind.endOfBook:
        return 'end-of-book';
    }
  }

  void _setFlatPages(List<_FlatPage> pages) {
    _flatPages = pages;
    _flatIndexByKey
      ..clear()
      ..addEntries(
        pages.asMap().entries.map(
              (entry) => MapEntry(_flatPageKey(entry.value), entry.key),
            ),
      );
  }

  int? _findIndexByPageKey(String key) => _flatIndexByKey[key];

  int? _findChildIndexByKey(Key key) {
    if (key is! ValueKey<String>) return null;
    return _findIndexByPageKey(key.value);
  }

  bool _isControllerScrolling() {
    final controller = _pageController;
    if (controller == null || !controller.hasClients) return _isScrolling;
    return controller.position.isScrollingNotifier.value;
  }

  String? _stableVisibleKeyFromController(List<_FlatPage> oldPages) {
    if (_pageController == null || !_pageController!.hasClients || oldPages.isEmpty) {
      return _currentPageKey;
    }

    final page = _pageController!.page;
    if (page == null) return _currentPageKey;

    // Avoid correcting while a drag/ballistic animation is between pages.
    final rounded = page.roundToDouble();
    if ((page - rounded).abs() > 0.01) {
      return _currentPageKey;
    }

    final index = rounded.toInt();
    if (index < 0 || index >= oldPages.length) return _currentPageKey;
    return _flatPageKey(oldPages[index]);
  }

  /// Find the flat index that best matches the current logical position.
  int _findCurrentFlatIndex(List<_FlatPage> pages) {
    if (_currentPageKey != null) {
      final byKey = _findIndexByPageKey(_currentPageKey!);
      if (byKey != null) return byKey;
    }

    if (_isOnEndOfBook) {
      // If user was on endOfBook, stay there if it still exists.
      for (int i = pages.length - 1; i >= 0; i--) {
        if (pages[i].kind == _FlatPageKind.endOfBook) return i;
      }
    }

    // Try exact match: same chapterId and pageIndexInChapter.
    for (int i = 0; i < pages.length; i++) {
      final p = pages[i];
      if (p.chapterId == _currentChapterId &&
          p.pageIndexInChapter == _currentPageInChapter &&
          p.kind == _FlatPageKind.content) {
        return i;
      }
    }

    // Fallback: same chapterId, any page (e.g., loading/error for that chapter).
    for (int i = 0; i < pages.length; i++) {
      if (pages[i].chapterId == _currentChapterId) return i;
    }

    // Last resort: stay at current index if valid.
    if (_currentFlatIndex < pages.length) return _currentFlatIndex;
    return pages.isEmpty ? 0 : pages.length - 1;
  }

  // ── Page changed callback ─────────────────────────────────────────────

  void _onPageChanged(int flatIndex) {
    if (_suppressPageChanged) return;
    if (flatIndex < 0 || flatIndex >= _flatPages.length) return;

    final page = _flatPages[flatIndex];
    _currentFlatIndex = flatIndex;
    _currentPageKey = _flatPageKey(page);

    _handleVisiblePageChange(page);
    _reportParagraphFromPage(page);

    _triggerPreload(_currentFlatIndex);
  }

  void _handleVisiblePageChange(_FlatPage page) {
    if (page.kind == _FlatPageKind.endOfBook) {
      _isOnEndOfBook = true;
      return;
    }

    _isOnEndOfBook = false;
    final chapterId = page.chapterId;
    if (chapterId == null || _isControllerScrolling()) return;

    _commitChapterSelection(
      chapterId: chapterId,
      pageInChapter: page.pageIndexInChapter,
    );
  }

  void _reportParagraphFromPage(_FlatPage page) {
    final pIdx = page.page?.firstParagraphIndex;
    if (pIdx == null || pIdx == _lastReportedParagraphIndex) return;
    _lastReportedParagraphIndex = pIdx;
    widget.onParagraphChanged(pIdx);
  }

  /// Recomputes the 3-window flat list and corrects the scroll position so
  /// that the visible page does not shift after a chapter boundary is crossed.
  /// Must only be called when scroll is idle; bails safely if called mid-scroll
  /// (the caller is responsible for re-invoking via [_onScrollingChanged]).
  void _applyWindowShiftImmediately() {
    // Never call jumpTo while a scroll gesture is in progress — it breaks
    // finger tracking.  _onScrollingChanged retries once the scroll settles.
    if (_isControllerScrolling()) return;
    if (_pageController == null ||
        !_pageController!.hasClients ||
        _pageBreaker == null) {
      return;
    }
    final anchorKey = _currentPageKey;
    if (anchorKey == null) return;

    final oldIndexByKey = Map<String, int>.from(_flatIndexByKey);

    // Rebuild flat list with the new chapter window.
    final newPages = _buildFlatPages();
    _setFlatPages(newPages);

    final oldIdx = oldIndexByKey[anchorKey];
    final newIdx = _flatIndexByKey[anchorKey];
    if (oldIdx == null || newIdx == null || oldIdx == newIdx) return;

    final pos = _pageController!.position;
    final viewportWidth = pos.viewportDimension;
    if (viewportWidth <= 0) return;

    final delta = (newIdx - oldIdx) * viewportWidth;
    _suppressPageChanged = true;
    _pageController!.jumpTo(pos.pixels + delta);
    _suppressPageChanged = false;
    _currentFlatIndex = newIdx;
  }

  // ── Scroll-state tracking ──────────────────────────────────────────────────

  /// Called whenever [PageController.position.isScrollingNotifier] changes.
  /// When the scroll fully stops and the chapter window is stale, applies
  /// the deferred window shift + position correction.
  void _onScrollingChanged() {
    if (_pageController == null || !_pageController!.hasClients) return;
    final nowScrolling =
        _pageController!.position.isScrollingNotifier.value;
    final wasScrolling = _isScrolling;
    _isScrolling = nowScrolling;

    if (!wasScrolling || nowScrolling) return;
    _commitSettledChapterAfterScroll();
    _flushDeferredAnchorCorrection();
  }

  void _flushDeferredAnchorCorrection() {
    // If build-phase anchor correction was deferred during drag, trigger
    // another build when scrolling becomes idle so remapping can run safely.
    if (!_deferAnchorCorrection) return;
    _deferAnchorCorrection = false;
    if (mounted) setState(() {});
  }

  void _commitChapterSelection({
    required String chapterId,
    required int pageInChapter,
  }) {
    final chapterChanged = _currentChapterId != chapterId;
    _currentChapterId = chapterId;
    _currentPageInChapter = pageInChapter;

    if (chapterChanged) {
      _applyWindowShiftImmediately();
    }

    if (_visibleChapterId != chapterId) {
      _visibleChapterId = chapterId;
      widget.loader.setCurrentChapter(chapterId);
      widget.onChapterChanged(chapterId);
    }
  }

  void _commitSettledChapterAfterScroll() {
    if (_pageController == null ||
        !_pageController!.hasClients ||
        _flatPages.isEmpty) {
      return;
    }

    final rawPage = _pageController!.page;
    if (rawPage == null) return;
    final settledIndex = rawPage.round().clamp(0, _flatPages.length - 1);
    final settledPage = _flatPages[settledIndex];
    _currentFlatIndex = settledIndex;
    _currentPageKey = _flatPageKey(settledPage);

    if (settledPage.kind == _FlatPageKind.endOfBook) {
      _isOnEndOfBook = true;
      return;
    }

    _isOnEndOfBook = false;
    final chapterId = settledPage.chapterId;
    if (chapterId == null) return;

    _commitChapterSelection(
      chapterId: chapterId,
      pageInChapter: settledPage.pageIndexInChapter,
    );
  }

  void _attachScrollingListener() {
    if (_pageController == null || !_pageController!.hasClients) return;
    _isScrolling = _pageController!.position.isScrollingNotifier.value;
    _pageController!.position.isScrollingNotifier
        .addListener(_onScrollingChanged);
  }

  void _detachScrollingListener() {
    if (_pageController != null && _pageController!.hasClients) {
      _pageController!.position.isScrollingNotifier
          .removeListener(_onScrollingChanged);
    }
  }

  void _scheduleAttachScrollingListener() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _attachScrollingListener();
    });
  }

  void _replacePageController(int initialPage) {
    _detachScrollingListener();
    _pageController?.dispose();
    _pageController = PageController(initialPage: initialPage);
    _scheduleAttachScrollingListener();
  }

  void _ensurePageController(int initialPage) {
    if (_pageController != null) return;
    _pageController = PageController(initialPage: initialPage);
    _scheduleAttachScrollingListener();
  }

  void _triggerPreload(int flatIndex) {
    final approachingEnd =
        flatIndex >= _flatPages.length - 3; // near the end
    final approachingStart = flatIndex <= 2; // near the start

    widget.loader.preloadIfNeeded(
      approachingEnd: approachingEnd,
      approachingStart: approachingStart,
    );
  }

  // ── Compute the initial page offset for the initial paragraph ─────────

  int _computeInitialPageOffset() {
    if (widget.initialParagraphIndex <= 0) return 0;
    final pages = _getPages(widget.initialChapterId);
    if (pages.isEmpty) return 0;
    return PageBreaker.pageForParagraph(pages, widget.initialParagraphIndex);
  }

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final contentSize = Size(
          constraints.maxWidth - widget.contentPadding.horizontal,
          constraints.maxHeight - widget.contentPadding.vertical,
        );
        _ensurePageBreaker(contentSize);

        // Empty / initial loading state.
        if (widget.loader.slots.isEmpty) {
          return Center(child: _buildLoadingPage(context));
        }

        // Build the flat page list.
        final newPages = _buildFlatPages();
        if (newPages.isEmpty) {
          return Center(child: _buildLoadingPage(context));
        }

        // Find where the user should be in the new list.
        final oldPages = _flatPages;
        final oldIndexByKey = Map<String, int>.from(_flatIndexByKey);
        final anchorKey = _stableVisibleKeyFromController(oldPages);

        _setFlatPages(newPages);

        if (!_initialJumpDone && _pageBreaker != null) {
          // First build: compute initial position.
          _initialJumpDone = true;
          _currentPageInChapter = _computeInitialPageOffset();
          _currentPageKey = 'content:${widget.initialChapterId}:$_currentPageInChapter';
          _currentFlatIndex = _findCurrentFlatIndex(_flatPages);
          _replacePageController(_currentFlatIndex);
        } else {
          // On subsequent updates, rely on stable keys +
          // findChildIndexCallback for child remapping.
          _currentFlatIndex = _findCurrentFlatIndex(_flatPages);
          _ensurePageController(_currentFlatIndex);

          // Keep viewport anchored to the same logical page when list shape
          // changes (e.g. loading page replaced by N content pages).
          if (anchorKey != null &&
              _pageController!.hasClients &&
              oldIndexByKey.containsKey(anchorKey) &&
              _flatIndexByKey.containsKey(anchorKey)) {
            final oldIdx = oldIndexByKey[anchorKey]!;
            final newIdx = _flatIndexByKey[anchorKey]!;
            if (oldIdx != newIdx) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted || _pageController == null || !_pageController!.hasClients) {
                  return;
                }
                if (_isControllerScrolling()) {
                  _deferAnchorCorrection = true;
                  return;
                }
                final pos = _pageController!.position;
                final viewportWidth = pos.viewportDimension;
                if (viewportWidth <= 0) return;

                final delta = (newIdx - oldIdx) * viewportWidth;
                _suppressPageChanged = true;
                _pageController!.jumpTo(pos.pixels + delta);
                _suppressPageChanged = false;
                _currentFlatIndex = newIdx;
              });
            }
          }
        }

        return PageView.builder(
          controller: _pageController!,
          onPageChanged: _onPageChanged,
          findChildIndexCallback: _findChildIndexByKey,
          itemCount: _flatPages.length,
          itemBuilder: (context, index) {
            if (index < 0 || index >= _flatPages.length) {
              return const SizedBox.shrink();
            }
            final page = _flatPages[index];
            return KeyedSubtree(
              key: ValueKey<String>(_flatPageKey(page)),
              child: _buildFlatPage(context, page),
            );
          },
        );
      },
    );
  }

  // ── Build a single flat page ──────────────────────────────────────────

  Widget _buildFlatPage(BuildContext context, _FlatPage page) {
    switch (page.kind) {
      case _FlatPageKind.content:
        return Padding(
          padding: widget.contentPadding,
          child: PageContentView(page: page.page!),
        );
      case _FlatPageKind.loading:
        return _buildLoadingPage(
          context,
          title: _chapterTitle(page.chapterId),
        );
      case _FlatPageKind.error:
        return _buildErrorPage(
          context,
          title: _chapterTitle(page.chapterId),
          errorMessage: page.errorMessage,
          onRetry: page.chapterId != null
              ? () => widget.loader.retryChapter(page.chapterId!)
              : null,
        );
      case _FlatPageKind.endOfBook:
        return _buildEndOfBookPage(context);
    }
  }

  String? _chapterTitle(String? chapterId) {
    if (chapterId == null) return null;
    final slot = widget.loader.getSlot(chapterId);
    if (slot != null && slot.isReady) {
      final paragraphs = slot.paragraphs;
      if (paragraphs != null && paragraphs.isNotEmpty) {
        final first = paragraphs.first;
        if (first is ParagraphContentTitle) return first.text;
      }
    }
    final l10n = AppLocalizations.of(context);
    final idx = widget.loader.chapterGlobalIndex(chapterId);
    return l10n.readerChapterFallbackTitle(idx + 1);
  }

  // ── UI builders ───────────────────────────────────────────────────────

  Widget _buildEndOfBookPage(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: widget.contentPadding,
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.check_circle_outline,
            size: 64,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            l10n.readerEndOfBook,
            style: Theme.of(context).textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingPage(BuildContext context, {String? title}) {
    return ChapterStatusBlock(
      kind: ChapterStatusBlockKind.loading,
      title: title,
      compact: false,
      padding: widget.contentPadding,
    );
  }

  Widget _buildErrorPage(
    BuildContext context, {
    Future<void> Function()? onRetry,
    String? title,
    String? errorMessage,
  }) {
    return ChapterStatusBlock(
      kind: ChapterStatusBlockKind.error,
      title: title,
      message: errorMessage,
      onRetry: onRetry,
      compact: false,
      padding: widget.contentPadding,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Resolved page model (public for testing)
// ─────────────────────────────────────────────────────────────────────────────

enum ResolvedPageKind {
  content,
  loading,
  error,
  bookInfo,
  endOfBook,
  loadingBoundary,
}

class ResolvedPage {
  final ResolvedPageKind kind;
  final String? chapterId;
  final PageContent? page;
  final String? errorMessage;

  const ResolvedPage._({
    required this.kind,
    this.chapterId,
    this.page,
    this.errorMessage,
  });

  const ResolvedPage.content({
    required String chapterId,
    required PageContent page,
  }) : this._(
          kind: ResolvedPageKind.content,
          chapterId: chapterId,
          page: page,
        );

  const ResolvedPage.loading({required String chapterId})
      : this._(kind: ResolvedPageKind.loading, chapterId: chapterId);

  const ResolvedPage.error({
    required String chapterId,
    String? errorMessage,
  }) : this._(
          kind: ResolvedPageKind.error,
          chapterId: chapterId,
          errorMessage: errorMessage,
        );

  const ResolvedPage.bookInfo() : this._(kind: ResolvedPageKind.bookInfo);
  const ResolvedPage.endOfBook() : this._(kind: ResolvedPageKind.endOfBook);
  const ResolvedPage.loadingBoundary()
      : this._(kind: ResolvedPageKind.loadingBoundary);
}

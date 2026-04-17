import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../src/rust/api/types.dart';
import 'chapter_status_block.dart';
import 'page_breaker.dart';
import 'page_content_view.dart';
import 'reader_types.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Horizontal reader view — single-chapter PageView with edge sentinels
//
// Sentinels show the REAL first/last page of the adjacent chapter when
// available (preloaded). This makes the cross-chapter swipe visually seamless:
// users see the actual next-chapter content while still physically on this
// widget, and the chapter boundary callback fires when the PageView settles,
// letting the parent slide the window without interrupting the animation.
// ─────────────────────────────────────────────────────────────────────────────

class HorizontalReaderView extends StatefulWidget {
  const HorizontalReaderView({
    super.key,
    required this.prevSlot,
    required this.centerSlot,
    required this.nextSlot,
    required this.centerChapterId,
    this.prevChapterId,
    this.nextChapterId,
    this.isLastChapter = false,
    required this.fontScale,
    required this.lineHeight,
    required this.contentPadding,
    required this.onChapterBoundary,
    required this.onPositionUpdate,
    required this.onRetry,
    this.initialParagraphIndex = 0,
    this.initialFromEnd = false,
    this.onJumpRegistered,
    this.onParagraphLongPress,
  });

  final ValueNotifier<ChapterLoadState> prevSlot;
  final ValueNotifier<ChapterLoadState> centerSlot;
  final ValueNotifier<ChapterLoadState> nextSlot;
  final String centerChapterId;
  final String? prevChapterId;
  final String? nextChapterId;
  final bool isLastChapter;
  final double fontScale;
  final double lineHeight;
  final EdgeInsets contentPadding;
  final void Function(ChapterDirection direction) onChapterBoundary;
  final void Function(String chapterId, int paragraphIndex, double offset)
      onPositionUpdate;
  final void Function(String chapterId) onRetry;
  final int initialParagraphIndex;
  final bool initialFromEnd;
  final ValueChanged<void Function(int, double)>? onJumpRegistered;
  final void Function(String chapterId, int paragraphIndex, ParagraphContent paragraph)? onParagraphLongPress;

  @override
  State<HorizontalReaderView> createState() => _HorizontalReaderViewState();
}

class _HorizontalReaderViewState extends State<HorizontalReaderView> {
  late PageController _pageController;
  bool _initialized = false;

  List<PageContent> _centerPages = [];

  // Suppresses onPageChanged side-effects during programmatic jumps.
  bool _suppressPageChange = false;

  // Per-chapter pages cache — avoids recomputing page breaks on every slide.
  final Map<String, List<PageContent>> _pagesCache = {};

  // Cached preview pages for adjacent sentinels (keyed by chapterId).
  PageContent? _prevPreviewPage; // last page of prev chapter
  PageContent? _nextPreviewPage; // first page of next chapter

  // Pending boundary — fired once the swipe animation settles.
  ChapterDirection? _pendingBoundary;

  bool get _hasPrev => widget.prevChapterId != null;
  bool get _hasNext =>
      widget.nextChapterId != null || widget.isLastChapter;

  int get _totalPages =>
      (_hasPrev ? 1 : 0) + _centerPages.length + (_hasNext ? 1 : 0);

  int get _centerOffset => _hasPrev ? 1 : 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    widget.onJumpRegistered?.call(_jumpToPosition);
    widget.prevSlot.addListener(_onPrevSlotChanged);
    widget.nextSlot.addListener(_onNextSlotChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      _centerPages = _computeCenterPages();
      _refreshPrevPreview();
      _refreshNextPreview();

      final initialPage = _initialCenterPage();
      _pageController.dispose();
      _pageController = PageController(initialPage: initialPage);
    }
  }

  int _initialCenterPage() {
    if (widget.initialFromEnd && _centerPages.isNotEmpty) {
      return _centerOffset + _centerPages.length - 1;
    }
    if (widget.initialParagraphIndex > 0 && _centerPages.isNotEmpty) {
      final local = PageBreaker.pageForParagraph(
        _centerPages,
        widget.initialParagraphIndex,
      );
      return _centerOffset + local;
    }
    return _centerOffset;
  }

  @override
  void didUpdateWidget(covariant HorizontalReaderView oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Font/line-height changes invalidate cached page breaks.
    if (oldWidget.fontScale != widget.fontScale ||
        oldWidget.lineHeight != widget.lineHeight ||
        oldWidget.contentPadding != widget.contentPadding) {
      _pagesCache.clear();
    }

    if (oldWidget.centerChapterId != widget.centerChapterId) {
      _centerPages = _computeCenterPages();
      _refreshPrevPreview();
      _refreshNextPreview();
      final target = _initialCenterPage();
      if (_pageController.hasClients) {
        _suppressPageChange = true;
        _pageController.jumpToPage(target);
        // Release suppression next frame so the deferred onPageChanged
        // (which PageView dispatches asynchronously) is still ignored.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _suppressPageChange = false;
        });
      } else {
        _pageController.dispose();
        _pageController = PageController(initialPage: target);
      }
    }
  }

  @override
  void dispose() {
    widget.prevSlot.removeListener(_onPrevSlotChanged);
    widget.nextSlot.removeListener(_onNextSlotChanged);
    _pageController.dispose();
    super.dispose();
  }

  void _onPrevSlotChanged() {
    if (!mounted) return;
    final before = _prevPreviewPage;
    _refreshPrevPreview();
    if (before != _prevPreviewPage) setState(() {});
  }

  void _onNextSlotChanged() {
    if (!mounted) return;
    final before = _nextPreviewPage;
    _refreshNextPreview();
    if (before != _nextPreviewPage) setState(() {});
  }

  void _refreshPrevPreview() {
    final state = widget.prevSlot.value;
    final id = widget.prevChapterId;
    if (state is ChapterLoaded && id != null) {
      final pages = _pagesFor(id, state.paragraphs);
      _prevPreviewPage = pages.isEmpty ? null : pages.last;
    } else {
      _prevPreviewPage = null;
    }
  }

  void _refreshNextPreview() {
    final state = widget.nextSlot.value;
    final id = widget.nextChapterId;
    if (state is ChapterLoaded && id != null) {
      final pages = _pagesFor(id, state.paragraphs);
      _nextPreviewPage = pages.isEmpty ? null : pages.first;
    } else {
      _nextPreviewPage = null;
    }
  }

  // ─ Jump ─────────────────────────────────────────────────────────────────

  void _jumpToPosition(int paragraphIndex, double _) {
    if (!_pageController.hasClients) return;
    final local = _centerPages.isNotEmpty
        ? PageBreaker.pageForParagraph(_centerPages, paragraphIndex)
        : 0;
    _suppressPageChange = true;
    _pageController.jumpToPage(_centerOffset + local);
    _suppressPageChange = false;
  }

  // ─ Page computation ─────────────────────────────────────────────────────

  List<PageContent> _computeCenterPages() {
    final state = widget.centerSlot.value;
    if (state is! ChapterLoaded) return [];
    return _pagesFor(widget.centerChapterId, state.paragraphs);
  }

  List<PageContent> _pagesFor(String chapterId, List paragraphs) {
    final cached = _pagesCache[chapterId];
    if (cached != null) return cached;
    final pages = _computePages(paragraphs);
    _pagesCache[chapterId] = pages;
    return pages;
  }

  List<PageContent> _computePages(List paragraphs) {
    final theme = Theme.of(context);
    final bodyLarge = theme.textTheme.bodyLarge?.copyWith(
      fontSize: (theme.textTheme.bodyLarge?.fontSize ?? 16) * widget.fontScale,
      height: widget.lineHeight,
    );
    final headlineSmall = theme.textTheme.headlineSmall?.copyWith(
      fontSize:
          (theme.textTheme.headlineSmall?.fontSize ?? 24) * widget.fontScale,
    );

    if (bodyLarge == null || headlineSmall == null) return [];

    final size = MediaQuery.sizeOf(context);
    final pageSize = Size(
      size.width - widget.contentPadding.horizontal,
      size.height - widget.contentPadding.vertical,
    );

    final breaker = PageBreaker(
      pageSize: pageSize,
      textStyle: bodyLarge,
      titleStyle: headlineSmall,
      paragraphSpacing: LanghuanTheme.spaceMd,
      imageHeight: pageSize.width * 9 / 16,
      textDirection: Directionality.of(context),
    );

    return breaker.computePages(paragraphs.cast());
  }

  // ─ Page change tracking ─────────────────────────────────────────────────

  void _onPageChanged(int pageIndex) {
    if (_suppressPageChange) return;

    if (_hasPrev && pageIndex == 0) {
      _pendingBoundary = ChapterDirection.previous;
      return;
    }

    if (_hasNext && pageIndex == _totalPages - 1) {
      if (widget.isLastChapter && widget.nextChapterId == null) {
        // End-of-book sentinel: nothing to slide to.
        return;
      }
      _pendingBoundary = ChapterDirection.next;
      return;
    }

    _pendingBoundary = null;
    final localIndex = pageIndex - _centerOffset;
    if (localIndex >= 0 && localIndex < _centerPages.length) {
      widget.onPositionUpdate(
        widget.centerChapterId,
        _centerPages[localIndex].firstParagraphIndex,
        0,
      );
    }
  }

  bool _onScrollNotification(ScrollNotification n) {
    if (n is ScrollEndNotification && _pendingBoundary != null) {
      final dir = _pendingBoundary!;
      _pendingBoundary = null;
      widget.onChapterBoundary(dir);
    }
    return false;
  }

  // ─ Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_centerPages.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: PageView.builder(
        controller: _pageController,
        itemCount: _totalPages,
        onPageChanged: _onPageChanged,
        itemBuilder: _buildPage,
      ),
    );
  }

  Widget _buildPage(BuildContext context, int index) {
    if (_hasPrev && index == 0) {
      return _buildAdjacentSentinel(
        slot: widget.prevSlot,
        chapterId: widget.prevChapterId!,
        previewPage: _prevPreviewPage,
      );
    }

    if (_hasNext && index == _totalPages - 1) {
      if (widget.isLastChapter && widget.nextChapterId == null) {
        return _buildEndOfBook(context);
      }
      return _buildAdjacentSentinel(
        slot: widget.nextSlot,
        chapterId: widget.nextChapterId!,
        previewPage: _nextPreviewPage,
      );
    }

    final localIndex = index - _centerOffset;
    return Padding(
      padding: widget.contentPadding,
      child: PageContentView(
        page: _centerPages[localIndex],
        fontScale: widget.fontScale,
        lineHeight: widget.lineHeight,
        onParagraphLongPress: widget.onParagraphLongPress != null
            ? (paragraphIndex, paragraph) =>
                widget.onParagraphLongPress!(widget.centerChapterId, paragraphIndex, paragraph)
            : null,
      ),
    );
  }

  /// Sentinel that shows the real adjacent page when cached, a loading or
  /// error block otherwise. Showing the real page is what makes chapter
  /// transitions seamless — no intermediate spinner flash.
  Widget _buildAdjacentSentinel({
    required ValueNotifier<ChapterLoadState> slot,
    required String chapterId,
    required PageContent? previewPage,
  }) {
    return ValueListenableBuilder<ChapterLoadState>(
      valueListenable: slot,
      builder: (_, state, _) {
        if (state is ChapterLoaded && previewPage != null) {
          return Padding(
            padding: widget.contentPadding,
            child: PageContentView(
              page: previewPage,
              fontScale: widget.fontScale,
              lineHeight: widget.lineHeight,
            ),
          );
        }
        if (state is ChapterLoadError) {
          return Center(
            child: ChapterStatusBlock(
              kind: ChapterStatusBlockKind.error,
              message: state.message,
              onRetry: () => widget.onRetry(chapterId),
            ),
          );
        }
        return const Center(
          child: ChapterStatusBlock(kind: ChapterStatusBlockKind.loading),
        );
      },
    );
  }

  Widget _buildEndOfBook(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Text(
        l10n.readerEndOfBook,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }
}

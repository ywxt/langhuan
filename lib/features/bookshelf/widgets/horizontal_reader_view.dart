import 'package:flutter/material.dart';

import '../../../shared/widgets/loading.dart';
import '../../../src/rust/api/types.dart';
import 'chapter_status_block.dart';
import 'page_content_view.dart';
import 'page_breaker.dart';
import 'reader_page_canvas_painter.dart';
import 'reader_pixel_aligned.dart';
import 'reader_end_page.dart';
import 'reader_desktop_controls.dart';

/// What a page slot of the paged reader shows.
///
/// The content manager resolves slots from a flat, cross-chapter page list,
/// so loading and error states of *neighboring chapters* flow through the
/// same channel as regular pages — turning past a chapter boundary is just
/// an index change, with no slide handshakes.
sealed class ReaderSlot {
  const ReaderSlot();
}

class ReaderSlotPage extends ReaderSlot {
  const ReaderSlotPage(this.page);

  final PageContent page;
}

/// The chapter's inline comment section, following its last text page.
/// Rendered live (never snapshot): the section loads and scrolls on its
/// own while it is on screen.
class ReaderSlotChapterEnd extends ReaderSlot {
  const ReaderSlotChapterEnd({required this.chapterId, this.chapterTitle});

  final String chapterId;
  final String? chapterTitle;
}

class ReaderSlotLoading extends ReaderSlot {
  const ReaderSlotLoading(this.chapterId, {this.chapterTitle});

  final String chapterId;
  final String? chapterTitle;
}

class ReaderSlotError extends ReaderSlot {
  const ReaderSlotError({
    required this.chapterId,
    this.chapterTitle,
    required this.error,
  });

  final String chapterId;
  final String? chapterTitle;

  /// Failure cause of this chapter's load.
  final Object error;
}

/// Horizontal paged reader.
///
/// Renders a 3-page strip (prev / current / next). Drag and settle gestures
/// move the strip; while a drag or animation is in flight the visible pages
/// are frozen (snapshot), and the offset resets atomically in the build that
/// delivers the new page after a turn — no intermediate-frame flash.
///
/// Tap zones: left third = previous page, right third = next page (both
/// animated like a swipe settle), middle third toggles the reader controls.
class HorizontalReaderView extends StatefulWidget {
  const HorizontalReaderView({
    super.key,
    required this.currentSlot,
    this.prevSlot,
    this.nextSlot,
    required this.isFirstPage,
    required this.isLastPage,
    required this.fontScale,
    this.fontFamily,
    this.letterSpacing = 0.0,
    this.paragraphSpacing = 16.0,
    required this.lineHeight,
    required this.contentPadding,
    required this.onNextPage,
    required this.onPrevPage,
    required this.onToggleControls,
    this.onPageTurnStart,
    this.onRetryChapter,
    this.onRefreshBook,
    this.onParagraphLongPress,
    this.selectedChapterId,
    this.selectedParagraphId,
    this.commentBadgeIdsOf,
    this.onParagraphComments,
    this.chapterEndBuilder,
  });

  final ReaderSlot? currentSlot;
  final ReaderSlot? prevSlot;
  final ReaderSlot? nextSlot;
  final bool isFirstPage;
  final bool isLastPage;
  final double fontScale;
  final String? fontFamily;
  final double letterSpacing;
  final double paragraphSpacing;
  final double lineHeight;
  final EdgeInsets contentPadding;
  final VoidCallback onNextPage;
  final VoidCallback onPrevPage;
  final VoidCallback onToggleControls;
  final VoidCallback? onPageTurnStart;
  final void Function(String chapterId)? onRetryChapter;
  final Future<void> Function()? onRefreshBook;

  final void Function(
    String chapterId,
    String paragraphId,
    ParagraphContent paragraph,
    Rect globalRect,
  )?
  onParagraphLongPress;

  final String? selectedChapterId;
  final String? selectedParagraphId;

  /// Per-chapter comment-badge paragraph identity sets (from the content
  /// manager). Null disables badges.
  final Set<String> Function(String chapterId)? commentBadgeIdsOf;

  /// Opens a paragraph's comments (badge tap). Only invoked for items that
  /// show a badge.
  final void Function(String chapterId, ParagraphContent paragraph)?
  onParagraphComments;

  /// Builds a chapter's inline end-of-chapter comment section; null when
  /// the reader's comment switch is off (the flat list then carries no
  /// chapter-end entries at all).
  final Widget? Function(String chapterId)? chapterEndBuilder;

  @override
  State<HorizontalReaderView> createState() => _HorizontalReaderViewState();
}

class _HorizontalReaderViewState extends State<HorizontalReaderView>
    with SingleTickerProviderStateMixin {
  late AnimationController _anim;
  late final SnapshotController _pageSnapshots;
  late final ReaderPageCanvasPainter _pagePainter;
  bool _dependenciesInitialized = false;
  bool _showEndPage = false;

  /// Pixel offset of the 3-page strip. 0 = center visible.
  /// Driven by drag or animation. Updated via ValueNotifier to avoid rebuild.
  final ValueNotifier<double> _offset = ValueNotifier(0);

  bool _isDragging = false;
  bool _isSettling = false;
  bool _holdingSettle = false;

  /// Frozen snapshot — only updated when idle (not dragging / settling).
  ReaderSlot? _snapCurrent;
  ReaderSlot? _snapPrev;
  ReaderSlot? _snapNext;
  bool _snapIsFirst = false;
  bool _snapIsLast = false;

  /// Direction the settle animation is heading: -1 next, 0 snap-back, 1 prev.
  int _settleDir = 0;

  /// True after settle animation completes but before the next build syncs
  /// the new props. Keeps [_busy] true so the snapshot stays frozen until
  /// the parent rebuild delivers the new page content.
  bool _pendingSettle = false;

  // Tween endpoints for the current settle animation.
  double _tweenStart = 0;
  double _tweenEnd = 0;

  static const _swipeFraction = 0.25;
  static const _velocityThreshold = 300.0; // px/s

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this)
      ..addListener(_onAnimTick)
      ..addStatusListener(_onAnimStatus);
    _pageSnapshots = SnapshotController(allowSnapshotting: true);
    _pagePainter = ReaderPageCanvasPainter();
    _syncSnapshot();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Register these dependencies on this State, not only on LayoutBuilder.
    // Otherwise a theme update rebuilds the live child beneath a stale image.
    Theme.of(context);
    MediaQuery.devicePixelRatioOf(context);
    if (_dependenciesInitialized) {
      // Theme, text scale, locale or device-pixel-ratio changes invalidate
      // the texture even when the PageContent object itself stayed stable.
      _pageSnapshots.clear();
    }
    _dependenciesInitialized = true;
  }

  @override
  void didUpdateWidget(covariant HorizontalReaderView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isLastPage ||
        (oldWidget.currentSlot is ReaderSlotPage &&
            widget.currentSlot is ReaderSlotPage &&
            !identical(
              (oldWidget.currentSlot as ReaderSlotPage).page,
              (widget.currentSlot as ReaderSlotPage).page,
            ))) {
      _showEndPage = false;
    }
    if (oldWidget.fontScale != widget.fontScale ||
        oldWidget.fontFamily != widget.fontFamily ||
        oldWidget.letterSpacing != widget.letterSpacing ||
        oldWidget.paragraphSpacing != widget.paragraphSpacing ||
        oldWidget.lineHeight != widget.lineHeight ||
        oldWidget.contentPadding != widget.contentPadding ||
        oldWidget.selectedChapterId != widget.selectedChapterId ||
        oldWidget.selectedParagraphId != widget.selectedParagraphId) {
      _pageSnapshots.clear();
    }
    // Badge visibility flipping (the lookup's null-ness) changes what pages
    // render without changing the PageContent objects — the slot keys stay
    // put, so the frozen snapshots must be dropped by hand to re-capture.
    if ((oldWidget.commentBadgeIdsOf == null) !=
        (widget.commentBadgeIdsOf == null)) {
      _pageSnapshots.clear();
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    _pageSnapshots.dispose();
    _pagePainter.dispose();
    _offset.dispose();
    super.dispose();
  }

  bool get _busy => _isDragging || _isSettling || _pendingSettle;

  void _syncSnapshot() {
    _snapCurrent = widget.currentSlot;
    _snapPrev = widget.prevSlot;
    _snapNext = widget.nextSlot;
    _snapIsFirst = widget.isFirstPage;
    _snapIsLast = widget.isLastPage;
  }

  bool get _canGoPrev => _showEndPage || _snapPrev != null || !_snapIsFirst;
  bool get _canGoNext =>
      !_showEndPage &&
      (_snapNext != null ||
          !_snapIsLast ||
          _snapCurrent is ReaderSlotPage ||
          // The chapter-end section is real content too: from the final
          // chapter's section, forward still flips to the end-of-book page.
          _snapCurrent is ReaderSlotChapterEnd);

  // ─ Gesture handling ───────────────────────────────────────────────────

  void _onDragDown(DragDownDetails _) {
    if (!_isSettling) return;
    // Stop at contact, rather than allowing the page to keep moving until
    // the drag recognizer crosses its touch-slop threshold.
    _holdingSettle = true;
    _anim.stop();
  }

  void _onDragStart(DragStartDetails _) {
    if (_isSettling) {
      _anim.stop();
      _isSettling = false;
    }
    _holdingSettle = false;
    widget.onPageTurnStart?.call();
    _isDragging = true;
  }

  void _onDragCancel(double pageWidth) {
    if (_holdingSettle) {
      _holdingSettle = false;
      _anim.forward();
    } else if (_isDragging) {
      _isDragging = false;
      _settleDir = 0;
      _animateTo(0, pageWidth);
    }
  }

  void _onDragUpdate(DragUpdateDetails details) {
    var next = _offset.value + details.delta.dx;
    if (!_canGoPrev && next > 0) next = 0;
    if (!_canGoNext && next < 0) next = 0;
    _offset.value = next;
  }

  void _onDragEnd(DragEndDetails details, double pageWidth) {
    _isDragging = false;

    final velocity = details.primaryVelocity ?? 0;
    final fraction = _offset.value / pageWidth;

    int dir = 0;
    if (velocity > _velocityThreshold && _canGoPrev) {
      dir = 1;
    } else if (velocity < -_velocityThreshold && _canGoNext) {
      dir = -1;
    } else if (fraction > _swipeFraction && _canGoPrev) {
      dir = 1;
    } else if (fraction < -_swipeFraction && _canGoNext) {
      dir = -1;
    }

    _settleDir = dir;
    _animateTo(dir * pageWidth, pageWidth);
  }

  void _onTapUp(TapUpDetails details, double pageWidth) {
    if (_busy) return;
    final dx = details.localPosition.dx;
    if (dx < pageWidth / 3) {
      // Animate the strip exactly like a swipe settle so tap turns and
      // drag turns share one motion language.
      if (_canGoPrev) {
        widget.onPageTurnStart?.call();
        _settleDir = 1;
        _animateTo(pageWidth, pageWidth);
      }
    } else if (dx > pageWidth * 2 / 3) {
      if (_canGoNext) {
        widget.onPageTurnStart?.call();
        _settleDir = -1;
        _animateTo(-pageWidth, pageWidth);
      }
    } else {
      widget.onToggleControls();
    }
  }

  void _turnFromDesktop(int direction, double pageWidth) {
    if (_busy) return;
    if (direction < 0 ? !_canGoNext : !_canGoPrev) return;
    widget.onPageTurnStart?.call();
    _settleDir = direction;
    _animateTo(direction * pageWidth, pageWidth);
  }

  void _animateTo(double target, double pageWidth) {
    _tweenStart = _offset.value;
    _tweenEnd = target;

    final distance = (target - _tweenStart).abs();
    final ms = (distance / pageWidth * 300).clamp(100.0, 350.0);

    _anim.duration = Duration(milliseconds: ms.toInt());
    // Set _isSettling AFTER reset so the dismissed status from reset()
    // doesn't trigger _onSettleComplete.
    _anim.reset();
    _isSettling = true;
    _anim.forward();
  }

  void _onAnimTick() {
    // Lerp between start and end using easeOut curve applied to controller value.
    final t = Curves.easeOut.transform(_anim.value);
    _offset.value = _tweenStart + (_tweenEnd - _tweenStart) * t;
  }

  void _onAnimStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      if (_isSettling) _onSettleComplete();
    }
  }

  void _onSettleComplete() {
    _isSettling = false;

    final dir = _settleDir;
    _settleDir = 0;

    if (dir == 0) {
      // Snap-back: no page change, just reset offset.
      _offset.value = 0;
      return;
    }

    if (_showEndPage || (dir == -1 && _snapIsLast && _snapNext == null)) {
      setState(() {
        _showEndPage = !_showEndPage;
        _offset.value = 0;
      });
      return;
    }

    // Page turn: keep the offset at the final position (±pageWidth) so the
    // old snapshot stays visually in place. Mark _pendingSettle so _busy
    // remains true until the parent rebuild delivers new props.
    _pendingSettle = true;

    if (dir == 1) {
      widget.onPrevPage();
    } else {
      widget.onNextPage();
    }
    // Parent calls setState → next build sees _pendingSettle, syncs snapshot,
    // resets offset to 0 atomically.
  }

  // ─ Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Sync snapshot when idle. When _pendingSettle is true, the parent just
    // delivered new props after a page turn — sync the snapshot and reset
    // offset to 0 in the same build frame so there's no visual flash.
    if (!_busy) {
      _syncSnapshot();
    } else if (_pendingSettle) {
      _pendingSettle = false;
      _syncSnapshot();
      _offset.value = 0;
    }

    if (_snapCurrent == null) {
      return const LoadingState();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final pageWidth = constraints.maxWidth;

        final prevSlot = _showEndPage ? _snapCurrent : _snapPrev;
        final currentSlot = _showEndPage ? null : _snapCurrent;
        final nextSlot = _showEndPage ? null : _snapNext;
        final prevChild = _showEndPage
            ? _buildCurrentPage(context)
            : _buildSlot(prevSlot, isPrev: true);
        final currentChild = _showEndPage
            ? _buildEndOfBook(context)
            : _buildCurrentPage(context);
        final nextChild = _showEndPage
            ? const SizedBox.shrink()
            : _buildSlot(nextSlot, isNext: true);

        // Keep page layout outside the animation builder and retain each text
        // page as a texture. On Impeller/OpenGLES, sliding live custom-font
        // text rebuilt the CJK glyph atlas on almost every frame. Stable keys
        // let a page carry its snapshot from next → current → previous while
        // the animation only translates the three-page strip.
        final pageStrip = Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              key: _slotKey(prevSlot, 'previous'),
              left: -pageWidth,
              top: 0,
              bottom: 0,
              width: pageWidth,
              child: _snapshotSlot(context, prevSlot, prevChild),
            ),
            Positioned.fill(
              key: _slotKey(currentSlot, 'current'),
              child: _snapshotSlot(context, currentSlot, currentChild),
            ),
            Positioned(
              key: _slotKey(nextSlot, 'next'),
              left: pageWidth,
              top: 0,
              bottom: 0,
              width: pageWidth,
              child: _snapshotSlot(context, nextSlot, nextChild),
            ),
          ],
        );

        return ReaderDesktopControls(
          onPrevious: () => _turnFromDesktop(1, pageWidth),
          onNext: () => _turnFromDesktop(-1, pageWidth),
          scrollToTurn: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragDown: _onDragDown,
            onHorizontalDragStart: _onDragStart,
            onHorizontalDragUpdate: _onDragUpdate,
            onHorizontalDragEnd: (d) => _onDragEnd(d, pageWidth),
            onHorizontalDragCancel: () => _onDragCancel(pageWidth),
            onTapUp: (d) => _onTapUp(d, pageWidth),
            child: ClipRect(
              child: ValueListenableBuilder<double>(
                valueListenable: _offset,
                child: pageStrip,
                builder: (context, offset, child) {
                  return Transform.translate(
                    key: const ValueKey('horizontal-reader-page-strip'),
                    offset: Offset(offset, 0),
                    transformHitTests: false,
                    child: ReaderPixelAligned(child: child!),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCurrentPage(BuildContext context) {
    return _buildSlotContent(_snapCurrent!, isCurrent: true);
  }

  Key _slotKey(ReaderSlot? slot, String fallback) {
    return switch (slot) {
      ReaderSlotPage(:final page) => ObjectKey(page),
      ReaderSlotChapterEnd(:final chapterId) => ValueKey(
        '$fallback-chapter-end-$chapterId',
      ),
      ReaderSlotLoading(:final chapterId) => ValueKey(
        '$fallback-loading-$chapterId',
      ),
      ReaderSlotError(:final chapterId) => ValueKey(
        '$fallback-error-$chapterId',
      ),
      null => ValueKey('$fallback-empty'),
    };
  }

  Widget _snapshotSlot(BuildContext context, ReaderSlot? slot, Widget child) {
    final page = RepaintBoundary(
      child: ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: child,
      ),
    );
    if (slot is! ReaderSlotPage) return page;
    // Retain the live page in its own layer as well as freezing it for the
    // translation. This lets Android reuse the already-painted page when a
    // new snapshot is captured after a turn instead of repainting all glyphs
    // into the snapshot from scratch.
    return SnapshotWidget(
      controller: _pageSnapshots,
      painter: _pagePainter,
      mode: SnapshotMode.permissive,
      child: page,
    );
  }

  Widget _buildSlot(
    ReaderSlot? slot, {
    bool isPrev = false,
    bool isNext = false,
  }) {
    if (slot == null) {
      if (isPrev && _snapIsFirst) {
        return const SizedBox.shrink();
      }
      if (isNext && _snapIsLast) {
        return _buildEndOfBook(context);
      }
      return const SizedBox.shrink();
    }
    return _buildSlotContent(slot);
  }

  Widget _buildSlotContent(ReaderSlot slot, {bool isCurrent = false}) {
    switch (slot) {
      case ReaderSlotPage(:final page):
        return Padding(
          padding: widget.contentPadding,
          child: PageContentView(
            page: page,
            fontScale: widget.fontScale,
            fontFamily: widget.fontFamily,
            letterSpacing: widget.letterSpacing,
            paragraphSpacing: widget.paragraphSpacing,
            lineHeight: widget.lineHeight,
            selectedParagraphId:
                isCurrent && widget.selectedChapterId == page.chapterId
                ? widget.selectedParagraphId
                : null,
            onParagraphLongPress: widget.onParagraphLongPress != null
                ? (paragraphId, paragraph, rect) =>
                      widget.onParagraphLongPress!(
                        page.chapterId,
                        paragraphId,
                        paragraph,
                        rect,
                      )
                : null,
            commentBadgeIds:
                widget.commentBadgeIdsOf?.call(page.chapterId) ?? const {},
            onParagraphComments: widget.onParagraphComments,
          ),
        );
      case ReaderSlotChapterEnd(:final chapterId):
        // Live interactive content: never enters the page-snapshot path.
        return Padding(
          padding: widget.contentPadding,
          child:
              widget.chapterEndBuilder?.call(chapterId) ??
              const SizedBox.shrink(),
        );
      case ReaderSlotLoading(:final chapterTitle):
        return Center(
          child: ChapterStatusBlock(
            kind: ChapterStatusBlockKind.loading,
            chapterTitle: chapterTitle,
          ),
        );
      case ReaderSlotError(:final chapterId, :final chapterTitle, :final error):
        return Center(
          child: ChapterStatusBlock(
            kind: ChapterStatusBlockKind.error,
            chapterTitle: chapterTitle,
            error: error,
            onRetry: widget.onRetryChapter != null
                ? () => widget.onRetryChapter!(chapterId)
                : null,
          ),
        );
    }
  }

  Widget _buildEndOfBook(BuildContext context) {
    return ReaderEndPage(
      onRefresh: widget.onRefreshBook,
      onReturnToText: _returnToText,
    );
  }

  void _returnToText() {
    if (!_showEndPage || _busy) return;
    final width = context.size?.width ?? 0;
    if (width <= 0) return;
    widget.onPageTurnStart?.call();
    _settleDir = 1;
    _animateTo(width, width);
  }
}

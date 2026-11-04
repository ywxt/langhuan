import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../src/rust/api/types.dart';
import '../../feeds/feed_service.dart'
    show ChapterInfoModel, ParagraphIdStringExt;
import 'chapter_status_block.dart';
import 'paragraph_view.dart';
import 'reader_chapter_window.dart';
import 'reader_pixel_aligned.dart';
import 'reader_types.dart';

/// A scroll target handed to [SeamlessVerticalReader].
///
/// `token` distinguishes consecutive targets (even identical ones) so the
/// view can react to every command. An empty `paragraphId` means "top of
/// chapter".
class ReaderScrollTarget {
  const ReaderScrollTarget({
    required this.token,
    required this.chapterId,
    this.paragraphId = '',
  });

  final int token;
  final String chapterId;
  final String paragraphId;
}

/// The result of probing which paragraphs are on screen.
class _VisibleProbe {
  const _VisibleProbe({
    required this.activeChapterId,
    required this.activeParagraphId,
    required this.activeParagraphOffset,
    required this.visibleChapterIds,
  });

  final String activeChapterId;
  final String activeParagraphId;
  final double activeParagraphOffset;
  final Set<String> visibleChapterIds;
}

/// Seamless vertical reader.
///
/// A [CustomScrollView] whose `center` is the *anchor* chapter's sliver —
/// the chat-log pattern. Chapters above the anchor live in the viewport's
/// reverse-growth region:
///
/// * prepending a chapter above (scrolling up) cannot move the anchor, so
///   it needs **no scroll-offset correction at all** — that is what makes
///   the scroll seamless in both directions;
/// * trimming far-away ends never shifts on-screen content either, because
///   pixels are measured from the anchor;
/// * when the reading position drifts far from the anchor,
///   [ReaderChapterWindow.maintainAround] moves the anchor onto it and the
///   view corrects the offset by the measured extent between the two
///   anchors *in the same frame* (via [ScrollPosition.correctPixels]).
///
/// Chapters flow with zero gap between them (無縫). Tap zones: top third
/// scrolls back one viewport, bottom third scrolls forward, middle toggles
/// the controls.
class SeamlessVerticalReader extends StatefulWidget {
  const SeamlessVerticalReader({
    super.key,
    required this.window,
    required this.chapters,
    required this.contentPadding,
    this.viewportBottomInset = 0,
    required this.fontScale,
    this.fontFamily,
    this.letterSpacing = 0.0,
    this.paragraphSpacing = LanghuanTheme.spaceMd,
    required this.lineHeight,
    required this.onPositionChanged,
    required this.onToggleControls,
    this.onParagraphLongPress,
    this.selectedChapterId,
    this.selectedParagraphId,
    this.scrollTarget,
    this.estimateParagraphOffset,
    this.onTargetSettled,
    this.commentBadgeIdsOf,
    this.onParagraphComments,
  });

  final ReaderChapterWindow window;
  final List<ChapterInfoModel> chapters;

  /// Horizontal padding applies per paragraph; the top applies once at the
  /// very top of the whole scroll content; the bottom is trailing scroll
  /// space reserved for chrome the viewport does *not* already avoid —
  /// with [viewportBottomInset] > 0 the viewport itself is inset past the
  /// chrome, so callers pass a zero bottom and pages rest no lower than
  /// the inset edge (a non-zero bottom would stack dead space at the
  /// book's end).
  final EdgeInsets contentPadding;

  /// Persistent bottom chrome (the reader status bar, including the
  /// safe-area inset) the scroll viewport must not lay content into:
  /// content scrolls *under* it while moving but can never come to rest
  /// beneath the status line.
  final double viewportBottomInset;

  final double fontScale;
  final String? fontFamily;
  final double letterSpacing;
  final double paragraphSpacing;
  final double lineHeight;

  /// Reports the first visible paragraph:
  /// (chapterId, paragraphId, pixels scrolled into that paragraph).
  final void Function(String chapterId, String paragraphId, double offset)
  onPositionChanged;
  final VoidCallback onToggleControls;

  final void Function(
    String chapterId,
    String paragraphId,
    ParagraphContent paragraph,
    Rect globalRect,
  )?
  onParagraphLongPress;

  final String? selectedChapterId;
  final String? selectedParagraphId;

  /// Restore/jump target; consumed after the first frame (or when the token
  /// changes on an already-mounted view).
  final ReaderScrollTarget? scrollTarget;

  /// Coarse pixel offset of a paragraph within its chapter, used to restore
  /// positions without laying out the whole chapter. Provided by the
  /// content manager (backed by [PageBreaker]). A `null` answer means the
  /// chapter is still being paginated: the current offset is held and the
  /// manager re-issues the target once the pages are complete.
  final double? Function(String chapterId, String paragraphId)?
  estimateParagraphOffset;

  /// Fired when the pending target has been landed on exactly (or was a
  /// chapter-start target, which lands on offset 0 by definition). The
  /// content manager cancels its deferred-estimate re-issue with it. Not
  /// fired when the walk gives up — there the re-issue stays armed as the
  /// last chance to land correctly.
  final VoidCallback? onTargetSettled;

  /// Identity strings of paragraphs that carry a comment badge, by chapter
  /// (computed by the content manager: last fragment per source paragraph
  /// with a positive comment count). Null/empty disables badges.
  final Set<String> Function(String chapterId)? commentBadgeIdsOf;

  /// Opens a paragraph's comments. Only invoked for paragraphs that show a
  /// badge — others keep the tap-to-toggle-controls behaviour.
  final void Function(String chapterId, ParagraphContent paragraph)?
  onParagraphComments;

  @override
  State<SeamlessVerticalReader> createState() => _SeamlessVerticalReaderState();
}

class _SeamlessVerticalReaderState extends State<SeamlessVerticalReader> {
  ScrollController? _controller;
  late Map<String, int> _chapterIndices;
  late Map<String, String> _chapterTitles;

  /// A stable zero point immediately before the current anchor chapter.
  /// Keeping the inset in its own center sliver means a TOC jump starts the
  /// target chapter below the requested top padding instead of reusing the
  /// previous chapter's scroll offset.
  static const _centerKey = ValueKey('vertical-anchor-inset');

  /// Stable sliver key per chapter — GlobalKeys so the probe can reach each
  /// sliver's render object.
  final Map<String, GlobalKey> _sliverKeys = {};

  /// Key of the paragraph the current scroll target points at, so
  /// [Scrollable.ensureVisible] can find it once it is built.
  final GlobalKey _targetItemKey = GlobalKey();
  String? _activeTargetParagraphId;
  ReaderScrollTarget? _pendingTarget;
  int _consumedTargetToken = -1;
  int _targetAttempts = 0;
  bool _ensureTargetScheduled = false;

  String _reportedParagraphKey = '';
  bool _reportScheduled = false;
  bool _pendingReportEnd = false;
  Timer? _reportThrottle;
  final Stopwatch _reportClock = Stopwatch()..start();
  bool _expandedAboveDuringScroll = false;
  bool _expandedBelowDuringScroll = false;
  static const _pageDuration = Duration(milliseconds: 260);
  static const _expandThresholdFactor = 1.5;
  static const _tapPageOverlap = 0.9;
  static const _reportInterval = Duration(milliseconds: 100);

  // ── Lifecycle ───────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _indexChapters();
    widget.window.addListener(_onWindowChanged);
    _pendingTarget = widget.scrollTarget;
    _consumedTargetToken = widget.scrollTarget?.token ?? -1;
    _activeTargetParagraphId = _paragraphIdOrNull(_pendingTarget);
    _scheduleEnsureTargetVisible();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The controller is created here (once) so the restore estimate can use
    // MediaQuery — creating it with the right initialScrollOffset avoids a
    // visible flash on open.
    if (_controller == null) {
      final target = _pendingTarget;
      var initial = 0.0;
      if (target != null && target.paragraphId.isNotEmpty) {
        initial =
            widget.estimateParagraphOffset?.call(
              target.chapterId,
              target.paragraphId,
            ) ??
            0.0;
      }
      _controller = ScrollController(initialScrollOffset: initial);
    }
  }

  @override
  void didUpdateWidget(covariant SeamlessVerticalReader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chapters != widget.chapters) _indexChapters();
    if (oldWidget.window != widget.window) {
      oldWidget.window.removeListener(_onWindowChanged);
      widget.window.addListener(_onWindowChanged);
    }
    final target = widget.scrollTarget;
    if (target != null && target.token != _consumedTargetToken) {
      _pendingTarget = target;
      _consumedTargetToken = target.token;
      _activeTargetParagraphId = _paragraphIdOrNull(target);
      _targetAttempts = 0;
      _applyTargetImmediately(target);
      _scheduleEnsureTargetVisible();
    }
  }

  @override
  void dispose() {
    widget.window.removeListener(_onWindowChanged);
    _reportThrottle?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  String? _paragraphIdOrNull(ReaderScrollTarget? target) =>
      (target != null && target.paragraphId.isNotEmpty)
      ? target.paragraphId
      : null;

  void _indexChapters() {
    _chapterIndices = <String, int>{
      for (var i = 0; i < widget.chapters.length; i++) widget.chapters[i].id: i,
    };
    _chapterTitles = <String, String>{
      for (final chapter in widget.chapters) chapter.id: chapter.title,
    };
  }

  void _onWindowChanged() {
    if (!mounted) return;
    if (_pendingTarget != null) _scheduleEnsureTargetVisible();
    setState(() {});
  }

  // ── Scroll targeting ────────────────────────────────────────────────────

  /// Mid-session jump: shift the pixels to the target estimate *before* the
  /// frame that rebuilds the slivers around the new anchor, so no frame is
  /// ever painted at a stale offset.
  void _applyTargetImmediately(ReaderScrollTarget target) {
    final controller = _controller;
    if (controller == null || !controller.hasClients) return;
    final position = controller.position;
    if (target.paragraphId.isEmpty) {
      position.correctPixels(0);
      return;
    }
    final estimate = widget.estimateParagraphOffset?.call(
      target.chapterId,
      target.paragraphId,
    );
    if (estimate == null) {
      // The chapter's pages are still being computed (pagination runs in
      // frame-budgeted slices now). Holding the current offset shows the
      // reflowed paragraphs in place; the fine-tune below lands exactly
      // once the target is built, and the manager re-issues the target
      // with a page estimate when pagination completes.
      return;
    }
    position.correctPixels(estimate);
  }

  /// Fine-tune the (already estimated) offset to land exactly on the target
  /// paragraph, once it has been built. Retries on window changes while the
  /// chapter is still loading; gives up once it finished without the item.
  void _scheduleEnsureTargetVisible() {
    if (_ensureTargetScheduled) return;
    _ensureTargetScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureTargetScheduled = false;
      if (!mounted || _pendingTarget == null) return;
      _ensureTargetVisible();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _ensureTargetVisible() {
    final target = _pendingTarget;
    if (target == null || !mounted) return;

    if (target.paragraphId.isEmpty) {
      _pendingTarget = null;
      _activeTargetParagraphId = null;
      widget.onTargetSettled?.call();
      return;
    }

    final context = _targetItemKey.currentContext;
    if (context != null) {
      Scrollable.ensureVisible(
        context,
        alignment: 0.0,
        duration: Duration.zero,
      );
      _pendingTarget = null;
      _activeTargetParagraphId = null;
      widget.onTargetSettled?.call();
      return;
    }

    final state = widget.window.stateOf(target.chapterId);
    if (state is ChapterLoaded &&
        _targetAttempts++ < 16 &&
        _advanceTowardTarget(target, state.paragraphs)) {
      _scheduleEnsureTargetVisible();
      return;
    }
    if (state is ChapterLoaded || state is ChapterLoadError) {
      // Content is there but the paragraph is not built — the coarse
      // estimate stands. Deliberately *not* settled: the manager's
      // re-issue may still land the estimate once pagination completes.
      _pendingTarget = null;
      _activeTargetParagraphId = null;
    }
  }

  // A page-based estimate can stop inside a very tall paragraph, leaving the
  // next paragraph unbuilt. Use measured sliver boundaries to bring the target
  // into the lazy layout before applying ensureVisible's exact correction.
  bool _advanceTowardTarget(
    ReaderScrollTarget target,
    List<ParagraphContent> paragraphs,
  ) {
    final controller = _controller;
    if (controller == null || !controller.hasClients) return false;
    final index = paragraphs.indexWhere(
      (p) => p.id.toStringValue() == target.paragraphId,
    );
    if (index < 0) return false;
    final sliver = _sliverKeyOf(
      target.chapterId,
    ).currentContext?.findRenderObject();
    if (sliver is! RenderSliverMultiBoxAdaptor) return false;
    final first = sliver.firstChild;
    final last = sliver.lastChild;
    if (first == null || last == null) return false;
    final reverse = _isBeforeAnchor(target.chapterId);
    final targetIndex = reverse ? paragraphs.length - 1 - index : index;
    final firstIndex = sliver.indexOf(first);
    final lastIndex = sliver.indexOf(last);
    if (targetIndex >= firstIndex && targetIndex <= lastIndex) return false;
    final after = targetIndex > lastIndex;
    final boundary = after ? last : first;
    final viewport = RenderAbstractViewport.of(boundary);
    final top = viewport.getOffsetToReveal(boundary, 0).offset;
    final position = controller.position;
    final offset =
        (top +
                ((after != reverse)
                    ? boundary.size.height
                    : -position.viewportDimension))
            .clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((offset - position.pixels).abs() < 1) return false;
    controller.jumpTo(offset);
    return true;
  }

  // ── Scroll notifications ────────────────────────────────────────────────

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification) {
      _expandedAboveDuringScroll = false;
      _expandedBelowDuringScroll = false;
    } else if (notification is ScrollUpdateNotification) {
      _maybeExpandWindow();
      _scheduleThrottledReport();
    } else if (notification is ScrollEndNotification) {
      _maybeExpandWindow();
      _reportThrottle?.cancel();
      _reportThrottle = null;
      _scheduleReport(end: true);
    }
    return false;
  }

  /// Position discovery walks the laid-out paragraph render objects. Doing
  /// that on every pointer event adds input latency without improving the
  /// persisted reading position, so sample it while moving and always take
  /// one exact sample when scrolling settles.
  void _scheduleThrottledReport() {
    if (_reportClock.elapsed >= _reportInterval) {
      _reportClock.reset();
      _scheduleReport();
      return;
    }
    if (_reportThrottle != null) return;
    _reportThrottle = Timer(_reportInterval - _reportClock.elapsed, () {
      _reportThrottle = null;
      if (!mounted) return;
      _reportClock.reset();
      _scheduleReport();
    });
  }

  /// Scroll notifications fire inside `setPixels`, *before* the frame lays
  /// out the new offset — probing paragraph positions right then reads the
  /// previous frame's layout. The probe is therefore deferred to a
  /// post-frame callback, with [ensureVisualUpdate] guaranteeing a frame
  /// runs even when the gesture already settled.
  void _scheduleReport({bool end = false}) {
    _pendingReportEnd = _pendingReportEnd || end;
    if (_reportScheduled) return;
    _reportScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reportScheduled = false;
      if (!mounted) return;
      final end = _pendingReportEnd;
      _pendingReportEnd = false;
      _maybeReportPosition(end: end);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _maybeExpandWindow() {
    final controller = _controller;
    if (controller == null || !controller.hasClients) return;
    final position = controller.position;
    final dim = position.viewportDimension;
    if (position.pixels - position.minScrollExtent <
            dim * _expandThresholdFactor &&
        !_expandedAboveDuringScroll) {
      _expandedAboveDuringScroll = true;
      widget.window.expandAbove();
    }
    if (position.maxScrollExtent - position.pixels <
            dim * _expandThresholdFactor &&
        !_expandedBelowDuringScroll) {
      _expandedBelowDuringScroll = true;
      widget.window.expandBelow();
    }
  }

  void _maybeReportPosition({bool end = false}) {
    final probe = _probeVisibleParagraphs();
    if (probe == null) return;

    widget.window.maintainAround(
      probe.activeChapterId,
      visibleChapterIds: probe.visibleChapterIds,
      onReanchor: _applyReanchorCorrection,
    );

    // Scroll notifications arrive at most once per frame; reporting is
    // further deduplicated to paragraph changes (the saved progress unit).
    final key = '${probe.activeChapterId}:${probe.activeParagraphId}';
    if (key != _reportedParagraphKey || end) {
      _reportedParagraphKey = key;
      widget.onPositionChanged(
        probe.activeChapterId,
        probe.activeParagraphId,
        probe.activeParagraphOffset,
      );
    }
  }

  /// Walks the chapter slivers and finds the first paragraph intersecting
  /// the viewport, plus every chapter with visible content.
  _VisibleProbe? _probeVisibleParagraphs() {
    final scrollContext = context;
    final renderObject = scrollContext.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return null;

    final viewportTop = renderObject.localToGlobal(Offset.zero).dy;
    final viewportBottom = viewportTop + renderObject.size.height;

    String? activeChapter;
    String? activeParagraph;
    var activeOffset = 0.0;
    var activeTop = double.infinity;
    final visible = <String>{};

    for (final chapterId in widget.window.windowChapterIds) {
      final paragraphs = widget.window.paragraphsOf(chapterId);
      if (paragraphs == null || paragraphs.isEmpty) continue;
      final sliverContext = _sliverKeyOf(chapterId).currentContext;
      if (sliverContext == null) continue;
      final sliverObject = sliverContext.findRenderObject();
      if (sliverObject is! RenderSliverMultiBoxAdaptor) continue;
      final beforeAnchor = _isBeforeAnchor(chapterId);

      RenderBox? child = sliverObject.firstChild;
      while (child != null) {
        final top = child.localToGlobal(Offset.zero).dy;
        final bottom = top + child.size.height;
        final intersectsViewport =
            bottom > viewportTop + 1.0 && top < viewportBottom - 1.0;
        if (intersectsViewport) {
          visible.add(chapterId);
          // Reverse-growth slivers enumerate children from the visual bottom
          // upward, so iteration order cannot identify the first visible
          // paragraph. Compare screen coordinates instead.
          if (top < activeTop) {
            final index = sliverObject.indexOf(child);
            if (index >= 0 && index < paragraphs.length) {
              final paragraphIndex = beforeAnchor
                  ? paragraphs.length - 1 - index
                  : index;
              activeTop = top;
              activeChapter = chapterId;
              activeParagraph = paragraphs[paragraphIndex].id.toStringValue();
              activeOffset = (viewportTop - top).clamp(0.0, child.size.height);
            }
          }
        }
        child = sliverObject.childAfter(child);
      }
    }

    if (activeChapter == null || activeParagraph == null) return null;
    return _VisibleProbe(
      activeChapterId: activeChapter,
      activeParagraphId: activeParagraph,
      activeParagraphOffset: activeOffset,
      visibleChapterIds: visible,
    );
  }

  /// Correct the scroll offset by the pixel extent between the old and the
  /// new anchor, measured from the *current* sliver geometry (all window
  /// slivers still exist when this runs — before the trim is applied).
  void _applyReanchorCorrection(WindowReanchor reanchor) {
    final controller = _controller;
    if (controller == null || !controller.hasClients) return;

    final oldIdx = _chapterIndex(reanchor.oldAnchorChapterId);
    final newIdx = _chapterIndex(reanchor.newAnchorChapterId);
    if (oldIdx < 0 || newIdx < 0 || oldIdx == newIdx) return;

    final lo = oldIdx < newIdx ? oldIdx : newIdx;
    final hi = oldIdx < newIdx ? newIdx : oldIdx;

    var extent = 0.0;
    for (var i = lo; i < hi; i++) {
      final sliverObject = _sliverKeyOf(
        widget.chapters[i].id,
      ).currentContext?.findRenderObject();
      if (sliverObject is RenderSliver) {
        extent += sliverObject.geometry?.scrollExtent ?? 0.0;
      }
    }

    final position = controller.position;
    // New anchor below the old one → origin moves down → pixels shrink.
    final shift = newIdx > oldIdx ? -extent : extent;
    position.correctPixels(position.pixels + shift);
  }

  int _chapterIndex(String chapterId) {
    return _chapterIndices[chapterId] ?? -1;
  }

  bool _isBeforeAnchor(String chapterId) {
    final chapterIndex = _chapterIndex(chapterId);
    final anchorIndex = _chapterIndex(widget.window.anchorChapterId);
    return chapterIndex >= 0 && anchorIndex >= 0 && chapterIndex < anchorIndex;
  }

  GlobalKey _sliverKeyOf(String chapterId) =>
      _sliverKeys.putIfAbsent(chapterId, GlobalKey.new);

  // ── Tap zones ───────────────────────────────────────────────────────────

  void _onTapUp(TapUpDetails details) {
    final height = context.size?.height ?? 0;
    if (height <= 0) return;
    final dy = details.localPosition.dy;
    if (dy < height / 3) {
      _page(-1);
    } else if (dy > height * 2 / 3) {
      _page(1);
    } else {
      widget.onToggleControls();
    }
  }

  /// Advance one viewport ([direction] 1 = forward, -1 = back) with a short
  /// overlap so a couple of lines carry over.
  void _page(int direction) {
    final controller = _controller;
    if (controller == null || !controller.hasClients) return;
    _maybeExpandWindow();
    final position = controller.position;
    final delta = position.viewportDimension * _tapPageOverlap * direction;
    final target = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    controller.animateTo(
      target,
      duration: _pageDuration,
      curve: Curves.easeOutCubic,
    );
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final window = widget.window;
    final chapterIds = window.windowChapterIds;
    final atBookEnd =
        !window.hasChapterBelow &&
        chapterIds.isNotEmpty &&
        window.stateOf(chapterIds.last) is ChapterLoaded;

    // Only one loading indicator is useful. Prefer the anchor (notably after
    // a TOC jump); otherwise show the loading edge the reader is approaching.
    String? loadingIndicatorChapterId;
    if (window.stateOf(window.anchorChapterId) is ChapterLoading) {
      loadingIndicatorChapterId = window.anchorChapterId;
    } else if (chapterIds.isNotEmpty &&
        window.stateOf(chapterIds.last) is ChapterLoading) {
      loadingIndicatorChapterId = chapterIds.last;
    } else if (chapterIds.isNotEmpty &&
        window.stateOf(chapterIds.first) is ChapterLoading) {
      loadingIndicatorChapterId = chapterIds.first;
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: _onTapUp,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScrollNotification,
        child: Padding(
          padding: EdgeInsets.only(bottom: widget.viewportBottomInset),
          child: CustomScrollView(
            controller: _controller,
            center: _centerKey,
            // The default 250 logical-pixel cache may not cover even one large
            // paragraph. Lay out two viewports ahead to reduce layout work as
            // paragraphs enter the screen during a drag.
            scrollCacheExtent: ScrollCacheExtent.pixels(
              MediaQuery.sizeOf(context).height * 2,
            ),
            slivers: [
              SliverToBoxAdapter(
                key: _topInsetKey,
                child: SizedBox(height: widget.contentPadding.top),
              ),
              for (final chapterId in chapterIds) ...[
                if (chapterId == window.anchorChapterId)
                  SliverToBoxAdapter(
                    key: _centerKey,
                    child: SizedBox(height: widget.contentPadding.top),
                  ),
                _buildChapterSliver(
                  chapterId,
                  showLoading: chapterId == loadingIndicatorChapterId,
                ),
              ],
              if (atBookEnd) const SliverToBoxAdapter(child: _EndOfBookMark()),
              if (widget.contentPadding.bottom > 0)
                SliverToBoxAdapter(
                  key: _bottomInsetKey,
                  child: SizedBox(height: widget.contentPadding.bottom),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static const _topInsetKey = ValueKey('vertical-top-inset');
  static const _bottomInsetKey = ValueKey('vertical-bottom-inset');

  Widget _buildChapterSliver(String chapterId, {required bool showLoading}) {
    final state = widget.window.stateOf(chapterId);
    final key = _sliverKeyOf(chapterId);

    if (state is ChapterLoaded) {
      final paragraphs = state.paragraphs;
      if (paragraphs.isEmpty) {
        return SliverToBoxAdapter(key: key, child: const SizedBox.shrink());
      }
      final beforeAnchor = _isBeforeAnchor(chapterId);
      return SliverList(
        key: key,
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            // Slivers before [CustomScrollView.center] use reverse growth:
            // child zero is placed closest to the center (the visual bottom).
            // Reverse their data index so paragraphs still read top-to-bottom
            // and the preceding chapter's title stays at its beginning.
            final paragraphIndex = beforeAnchor
                ? paragraphs.length - 1 - index
                : index;
            return _buildParagraphItem(chapterId, paragraphs[paragraphIndex]);
          },
          childCount: paragraphs.length,
          addRepaintBoundaries: false,
        ),
      );
    }

    if (state is ChapterLoadError) {
      return SliverToBoxAdapter(
        key: key,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 32),
          child: ChapterStatusBlock(
            kind: ChapterStatusBlockKind.error,
            chapterTitle: _chapterTitleOf(chapterId),
            error: state.error,
            onRetry: () => widget.window.retry(chapterId),
          ),
        ),
      );
    }

    return SliverToBoxAdapter(
      key: key,
      child: showLoading
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: ChapterStatusBlock(
                kind: ChapterStatusBlockKind.loading,
                chapterTitle: _chapterTitleOf(chapterId),
              ),
            )
          : const SizedBox.shrink(),
    );
  }

  String? _chapterTitleOf(String chapterId) {
    return _chapterTitles[chapterId];
  }

  Widget _buildParagraphItem(String chapterId, ParagraphContent paragraph) {
    final paragraphId = paragraph.id.toStringValue();
    final isTarget =
        chapterId == _pendingTarget?.chapterId &&
        paragraphId == _activeTargetParagraphId;
    final selected =
        widget.selectedChapterId == chapterId &&
        widget.selectedParagraphId == paragraphId;

    final badgeCount = _commentBadgeCount(chapterId, paragraphId, paragraph);

    return KeyedSubtree(
      key: isTarget ? _targetItemKey : ValueKey('$chapterId:$paragraphId'),
      child: Padding(
        padding: EdgeInsets.only(
          left: widget.contentPadding.left,
          right: widget.contentPadding.right,
          bottom: widget.paragraphSpacing,
        ),
        child: ReaderPixelAligned(
          child: RepaintBoundary(
            child: ParagraphView(
              paragraph: paragraph,
              fontScale: widget.fontScale,
              fontFamily: widget.fontFamily,
              letterSpacing: widget.letterSpacing,
              paragraphSpacing: widget.paragraphSpacing,
              lineHeight: widget.lineHeight,
              selected: selected,
              onLongPress: widget.onParagraphLongPress != null
                  ? (rect) => widget.onParagraphLongPress!(
                      chapterId,
                      paragraphId,
                      paragraph,
                      rect,
                    )
                  : null,
              commentCount: badgeCount,
              onCommentTap: badgeCount == null
                  ? null
                  : () => widget.onParagraphComments!(chapterId, paragraph),
            ),
          ),
        ),
      ),
    );
  }

  /// The badge count for a paragraph, or null when it shows no badge —
  /// either no count, zero comments, or a later fragment of a source
  /// paragraph whose badge already showed earlier.
  int? _commentBadgeCount(
    String chapterId,
    String paragraphId,
    ParagraphContent paragraph,
  ) {
    final count = paragraph.commentCount;
    if (count == null || count <= 0) return null;
    final badges = widget.commentBadgeIdsOf?.call(chapterId);
    if (badges == null || !badges.contains(paragraphId)) return null;
    return count;
  }
}

class _EndOfBookMark extends StatelessWidget {
  const _EndOfBookMark();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Center(
        child: Text(
          AppLocalizations.of(context).readerEndOfBook,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

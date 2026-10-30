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
  });

  final ReaderChapterWindow window;
  final List<ChapterInfoModel> chapters;

  /// Horizontal padding applies per paragraph; the vertical components
  /// apply once at the very top/bottom of the whole scroll content.
  final EdgeInsets contentPadding;

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
  /// content manager (backed by [PageBreaker]).
  final double? Function(String chapterId, String paragraphId)?
  estimateParagraphOffset;

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

  String _reportedParagraphKey = '';
  bool _reportScheduled = false;
  bool _pendingReportEnd = false;
  static const _pageDuration = Duration(milliseconds: 260);
  static const _expandThresholdFactor = 1.5;
  static const _tapPageOverlap = 0.9;

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
      _applyTargetImmediately(target);
      _scheduleEnsureTargetVisible();
    }
  }

  @override
  void dispose() {
    widget.window.removeListener(_onWindowChanged);
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
    final estimate = target.paragraphId.isEmpty
        ? 0.0
        : widget.estimateParagraphOffset?.call(
                target.chapterId,
                target.paragraphId,
              ) ??
              0.0;
    position.correctPixels(estimate);
  }

  /// Fine-tune the (already estimated) offset to land exactly on the target
  /// paragraph, once it has been built. Retries on window changes while the
  /// chapter is still loading; gives up once it finished without the item.
  void _scheduleEnsureTargetVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pendingTarget == null) return;
      _ensureTargetVisible();
    });
  }

  void _ensureTargetVisible() {
    final target = _pendingTarget;
    if (target == null || !mounted) return;

    if (target.paragraphId.isEmpty) {
      _pendingTarget = null;
      _activeTargetParagraphId = null;
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
      return;
    }

    final state = widget.window.stateOf(target.chapterId);
    if (state is ChapterLoaded || state is ChapterLoadError) {
      // Content is there but the paragraph is not built — the coarse
      // estimate stands.
      _pendingTarget = null;
      _activeTargetParagraphId = null;
    }
  }

  // ── Scroll notifications ────────────────────────────────────────────────

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollUpdateNotification ||
        notification is ScrollEndNotification ||
        notification is UserScrollNotification) {
      if (notification is ScrollEndNotification) _pendingReportEnd = true;
      _maybeExpandWindow();
      _scheduleReport();
    }
    return false;
  }

  /// Scroll notifications fire inside `setPixels`, *before* the frame lays
  /// out the new offset — probing paragraph positions right then reads the
  /// previous frame's layout. The probe is therefore deferred to a
  /// post-frame callback, with [ensureVisualUpdate] guaranteeing a frame
  /// runs even when the gesture already settled.
  void _scheduleReport() {
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
        dim * _expandThresholdFactor) {
      widget.window.expandAbove();
    }
    if (position.maxScrollExtent - position.pixels <
        dim * _expandThresholdFactor) {
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
        child: CustomScrollView(
          controller: _controller,
          center: _centerKey,
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
            SliverToBoxAdapter(
              key: _bottomInsetKey,
              child: SizedBox(height: widget.contentPadding.bottom),
            ),
          ],
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
        delegate: SliverChildBuilderDelegate((context, index) {
          // Slivers before [CustomScrollView.center] use reverse growth:
          // child zero is placed closest to the center (the visual bottom).
          // Reverse their data index so paragraphs still read top-to-bottom
          // and the preceding chapter's title stays at its beginning.
          final paragraphIndex = beforeAnchor
              ? paragraphs.length - 1 - index
              : index;
          return _buildParagraphItem(chapterId, paragraphs[paragraphIndex]);
        }, childCount: paragraphs.length),
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
    final isTarget = paragraphId == _activeTargetParagraphId;
    final selected =
        widget.selectedChapterId == chapterId &&
        widget.selectedParagraphId == paragraphId;

    return KeyedSubtree(
      key: isTarget ? _targetItemKey : ValueKey('$chapterId:$paragraphId'),
      child: Padding(
        padding: EdgeInsets.only(
          left: widget.contentPadding.left,
          right: widget.contentPadding.right,
          bottom: widget.paragraphSpacing,
        ),
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
        ),
      ),
    );
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

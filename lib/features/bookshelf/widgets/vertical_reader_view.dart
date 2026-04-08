import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../l10n/app_localizations.dart';
import '../../../src/bindings/signals/signals.dart';
import 'chapter_loader.dart';
import 'chapter_status_block.dart';
import 'paragraph_view.dart';
import 'reader_display_mapper.dart';
import 'reader_types.dart';

// ─────────────────────────────────────────────────────────────────────────────
// VerticalReaderView — per-chapter sliver architecture
//
// Each chapter is rendered as one SliverToBoxAdapter containing a Column of
// all its paragraphs (or a loading/error placeholder).  The CustomScrollView
// stitches them together with a `center` key on the current chapter's sliver
// so that additions above/below never shift the viewport.
// ─────────────────────────────────────────────────────────────────────────────

class VerticalReaderView extends StatefulWidget {
  const VerticalReaderView({
    super.key,
    required this.loader,
    required this.initialChapterId,
    required this.initialParagraphIndex,
    this.initialParagraphOffset = 0,
    required this.contentPadding,
    required this.onChapterChanged,
    required this.onParagraphChanged,
    required this.onParagraphOffsetChanged,
  });

  final ChapterLoader loader;
  final String initialChapterId;
  final int initialParagraphIndex;
  final double initialParagraphOffset;
  final EdgeInsets contentPadding;
  final ValueChanged<String> onChapterChanged;
  final ValueChanged<int> onParagraphChanged;
  final ValueChanged<double> onParagraphOffsetChanged;

  @override
  State<VerticalReaderView> createState() => _VerticalReaderViewState();
}

class _VerticalReaderViewState extends State<VerticalReaderView> {
  ScrollController _scrollController = ScrollController();

  /// The chapter that sits at scroll offset 0 (the center key target).
  late String _centerChapterId;

  /// Key for the center sliver.
  final _centerSliverKey = GlobalKey();

  /// GlobalKeys for content paragraphs — used for scroll-to and detection.
  final Map<String, GlobalKey> _paragraphKeys = {};

  bool _needsInitialScroll = true;
  bool _suppressDetection = false;
  String? _visibleChapterId;
  _VisiblePosition? _pendingPosition;

  /// The last position we reported upward via _commitPosition.
  ({String chapterId, int paragraphIndex, double paragraphOffset})?
      _lastReportedPosition;

  // ─ Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _centerChapterId = widget.initialChapterId;
    _scrollController.addListener(_onScroll);
    widget.loader.addListener(_onLoaderChanged);
  }

  @override
  void dispose() {
    widget.loader.removeListener(_onLoaderChanged);
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(VerticalReaderView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.loader != widget.loader) {
      oldWidget.loader.removeListener(_onLoaderChanged);
      widget.loader.addListener(_onLoaderChanged);
    }

    final positionChanged =
        oldWidget.initialChapterId != widget.initialChapterId ||
            oldWidget.initialParagraphIndex != widget.initialParagraphIndex ||
            oldWidget.initialParagraphOffset != widget.initialParagraphOffset;

    if (!positionChanged) return;

    // Ignore position changes that we ourselves reported upward.
    final lrp = _lastReportedPosition;
    if (lrp != null) {
      _lastReportedPosition = null;
      if (lrp.chapterId == widget.initialChapterId &&
          lrp.paragraphIndex == widget.initialParagraphIndex &&
          lrp.paragraphOffset == widget.initialParagraphOffset) {
        return;
      }
    }

    if (widget.initialChapterId.isNotEmpty) {
      _jumpToChapter(
        widget.initialChapterId,
        widget.initialParagraphIndex,
        widget.initialParagraphOffset,
      );
    }
  }

  void _onLoaderChanged() {
    if (mounted) setState(() {});
  }

  // ─ Chapter jump (from TOC / bottom bar) ──────────────────────────────────

  void _jumpToChapter(String chapterId, int paragraph, double offset) {
    _pendingPosition = null;
    _centerChapterId = chapterId;
    _lastReportedPosition = null;
    _visibleChapterId = chapterId;
    _paragraphKeys.clear();

    // Replace scroll controller so the center chapter starts at offset 0.
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _scrollController = ScrollController()..addListener(_onScroll);

    _suppressDetection = true;

    if (paragraph > 0 || offset > 0) {
      _scrollToChapterParagraph(chapterId, paragraph, offset);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _suppressDetection = false;
        _onScrollEnd();
      });
    }
    if (mounted) setState(() {});
  }

  // ─ Scroll detection ──────────────────────────────────────────────────────

  void _onScroll() {
    if (!_scrollController.hasClients || _suppressDetection) return;
    final pos = _detectVisiblePosition();
    if (pos != null) _pendingPosition = pos;

    // Trigger preloading when approaching the edges of loaded content.
    _triggerEdgePreload();
  }

  /// Ask the loader to preload the next/previous chapter when the scroll
  /// position is within a threshold of the content boundary.  This makes
  /// new chapters appear seamlessly as the user scrolls.
  void _triggerEdgePreload() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    const threshold = 300.0; // px before reaching the edge

    final approachingEnd =
        pos.maxScrollExtent - pos.pixels < threshold;
    final approachingStart =
        pos.pixels - pos.minScrollExtent < threshold;

    if (approachingEnd || approachingStart) {
      widget.loader.preloadIfNeeded(
        approachingEnd: approachingEnd,
        approachingStart: approachingStart,
      );
    }
  }

  void _onScrollEnd() {
    if (_pendingPosition != null) {
      final pos = _pendingPosition!;
      _pendingPosition = null;
      _commitPosition(pos);
    } else {
      final pos = _detectVisiblePosition();
      if (pos != null) _commitPosition(pos);
    }
  }

  void _commitPosition(_VisiblePosition pos) {
    _lastReportedPosition = (
      chapterId: pos.chapterId,
      paragraphIndex: pos.paragraphIndex,
      paragraphOffset: pos.paragraphOffset,
    );
    if (_visibleChapterId != pos.chapterId) {
      _visibleChapterId = pos.chapterId;
      widget.loader.setCurrentChapter(pos.chapterId);
      widget.onChapterChanged(pos.chapterId);
    }
    widget.onParagraphChanged(pos.paragraphIndex);
    widget.onParagraphOffsetChanged(pos.paragraphOffset);
  }

  _VisiblePosition? _detectVisiblePosition() {
    if (!_scrollController.hasClients) return null;

    _VisiblePosition? best;
    double bestDist = double.infinity;

    for (final entry in _paragraphKeys.entries) {
      final gk = entry.value;
      if (gk.currentContext == null) continue;
      final ro = gk.currentContext!.findRenderObject();
      if (ro is! RenderBox || !ro.attached) continue;

      final vp = RenderAbstractViewport.of(ro);
      final revealed = vp.getOffsetToReveal(ro, 0.0);
      final rel = revealed.offset - _scrollController.offset;

      if (rel > -ro.size.height && rel <= 0) {
        final dist = rel.abs();
        if (dist < bestDist) {
          bestDist = dist;
          final parts = entry.key.split(':');
          if (parts.length == 2) {
            best = _VisiblePosition(
              chapterId: parts[0],
              paragraphIndex: int.tryParse(parts[1]) ?? 0,
              paragraphOffset: (-rel).clamp(0.0, ro.size.height).toDouble(),
            );
          }
        }
      }
    }

    return best;
  }

  // ─ Scroll to a specific paragraph ────────────────────────────────────────

  void _scrollToChapterParagraph(
    String chapterId,
    int paragraphIndex,
    double paragraphOffset, {
    int attempt = 0,
  }) {
    _suppressDetection = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _suppressDetection = false;
        return;
      }

      final keyStr = '$chapterId:$paragraphIndex';
      final key = _paragraphKeys[keyStr];

      if (key == null || key.currentContext == null) {
        // Each chapter is a single Column so all paragraphs are laid out
        // at once.  If the key doesn't exist the chapter hasn't loaded yet;
        // retry next frame.
        if (attempt < 10) {
          _scrollToChapterParagraph(
            chapterId,
            paragraphIndex,
            paragraphOffset,
            attempt: attempt + 1,
          );
        } else {
          _suppressDetection = false;
        }
        return;
      }

      Scrollable.ensureVisible(
        key.currentContext!,
        alignment: 0.0,
        duration: Duration.zero,
      ).then((_) {
        if (!mounted) return;
        if (paragraphOffset > 0 && _scrollController.hasClients) {
          final pos = _scrollController.position;
          final target = (_scrollController.offset + paragraphOffset)
              .clamp(pos.minScrollExtent, pos.maxScrollExtent)
              .toDouble();
          if ((target - _scrollController.offset).abs() > 0.5) {
            _scrollController.jumpTo(target);
          }
        }
        _suppressDetection = false;
        _onScrollEnd();
      });
    });
  }

  // ─ Key helpers ───────────────────────────────────────────────────────────

  GlobalKey _getOrCreateKey(String chapterId, int paragraphIndex) {
    final keyStr = '$chapterId:$paragraphIndex';
    return _paragraphKeys.putIfAbsent(keyStr, () => GlobalKey());
  }

  void _pruneKeys(Set<String> validChapterIds) {
    _paragraphKeys.removeWhere((key, _) {
      final chId = key.split(':').first;
      return !validChapterIds.contains(chId);
    });
  }

  // ─ Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final slots = widget.loader.slots;

    if (slots.isEmpty) {
      return const Center(
        child: ChapterStatusBlock(
          kind: ChapterStatusBlockKind.loading,
          compact: false,
          padding: EdgeInsets.all(32),
        ),
      );
    }

    // Find the center slot index.
    int centerIdx = slots.indexWhere((s) => s.chapterId == _centerChapterId);
    if (centerIdx < 0) centerIdx = 0;

    // Prune paragraph keys for chapters no longer in slots.
    final validIds = slots.map((s) => s.chapterId).toSet();
    _pruneKeys(validIds);

    // Handle initial scroll.
    if (_needsInitialScroll) {
      _needsInitialScroll = false;
      if (widget.initialParagraphIndex > 0 ||
          widget.initialParagraphOffset > 0) {
        _scrollToChapterParagraph(
          widget.initialChapterId,
          widget.initialParagraphIndex,
          widget.initialParagraphOffset,
        );
      }
    }

    final hPad = widget.contentPadding.left;

    // ── Before-center slivers (reversed for upward growth) ─────────────
    final beforeSlivers = <Widget>[];
    for (int i = centerIdx - 1; i >= 0; i--) {
      final isTopmost = i == 0;
      beforeSlivers.add(
        SliverToBoxAdapter(
          key: ValueKey('ch-${slots[i].chapterId}'),
          child: Padding(
            padding: EdgeInsets.only(
              left: hPad,
              right: hPad,
              top: isTopmost ? widget.contentPadding.top : 0,
            ),
            child: _buildChapterColumn(
              context,
              slots[i],
              showSeparator: !isTopmost,
            ),
          ),
        ),
      );
    }

    // ── Center + forward slivers ───────────────────────────────────────
    final forwardSlivers = <Widget>[];
    for (int i = centerIdx; i < slots.length; i++) {
      final isCenter = i == centerIdx;
      final isTopmost = centerIdx == 0 && i == 0;
      forwardSlivers.add(
        SliverToBoxAdapter(
          key: isCenter
              ? _centerSliverKey
              : ValueKey('ch-${slots[i].chapterId}'),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: hPad),
            child: _buildChapterColumn(
              context,
              slots[i],
              showSeparator: !isTopmost,
            ),
          ),
        ),
      );
    }

    // Bottom boundary.
    forwardSlivers.add(
      SliverPadding(
        padding: EdgeInsets.only(bottom: widget.contentPadding.bottom),
        sliver: SliverToBoxAdapter(child: _buildBottomBoundary(context)),
      ),
    );

    return NotificationListener<ScrollEndNotification>(
      onNotification: (notification) {
        _onScrollEnd();
        return false;
      },
      child: CustomScrollView(
        controller: _scrollController,
        center: _centerSliverKey,
        slivers: [
          ...beforeSlivers,
          ...forwardSlivers,
        ],
      ),
    );
  }

  // ─ Per-chapter widget builder ────────────────────────────────────────────

  /// Builds one chapter as a Column: optional separator, then either
  /// loading/error placeholder or the full list of paragraphs.
  Widget _buildChapterColumn(
    BuildContext context,
    ChapterSlot slot, {
    required bool showSeparator,
  }) {
    if (slot.isLoading) {
      return _buildChapterMarker(
        context,
        title: _slotTitle(slot),
        kind: ChapterDisplayKind.loading,
        chapterId: slot.chapterId,
        showSeparator: showSeparator,
      );
    }

    if (slot.isError) {
      return _buildChapterMarker(
        context,
        title: _slotTitle(slot),
        kind: ChapterDisplayKind.error,
        chapterId: slot.chapterId,
        errorMessage: slot.errorMessage,
        showSeparator: showSeparator,
      );
    }

    // Ready — build all paragraphs in a single Column.
    final paragraphs = slot.paragraphs ?? const <ParagraphContent>[];
    final title = _resolveTitle(paragraphs, slot);

    // Skip the first paragraph if it is the title (already shown as header).
    final hasInlineTitle =
        paragraphs.isNotEmpty && paragraphs.first is ParagraphContentTitle;
    final startIndex = hasInlineTitle ? 1 : 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showSeparator) ...[
          const Divider(),
          const SizedBox(height: 8),
        ],
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(
            title,
            style: Theme.of(context).textTheme.labelMedium,
            textAlign: TextAlign.center,
          ),
        ),
        for (int pi = startIndex; pi < paragraphs.length; pi++)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: ParagraphView(
              key: _getOrCreateKey(slot.chapterId, pi),
              item: paragraphs[pi],
            ),
          ),
      ],
    );
  }

  // ─ Helpers ───────────────────────────────────────────────────────────────

  String _slotTitle(ChapterSlot slot) {
    final ch = widget.loader.chapterByTocIndex(slot.chapterIndex);
    return ch?.title ?? 'Chapter ${slot.chapterIndex + 1}';
  }

  String _resolveTitle(List<ParagraphContent> paragraphs, ChapterSlot slot) {
    if (paragraphs.isNotEmpty && paragraphs.first is ParagraphContentTitle) {
      return (paragraphs.first as ParagraphContentTitle).text;
    }
    return _slotTitle(slot);
  }

  // ─ Boundary widgets ──────────────────────────────────────────────────────

  Widget _buildBottomBoundary(BuildContext context) {
    final isTrueBookEnd =
        widget.loader.isAtBookEnd && !widget.loader.hasNewerUnloaded;
    if (isTrueBookEnd) return _buildEndOfBookBlock(context);

    // Not at the end of the book — the preloading mechanism will add new
    // chapter slivers (with their own loading/error states) seamlessly.
    // Show nothing here so there is no redundant loading indicator.
    return const SizedBox.shrink();
  }

  Widget _buildEndOfBookBlock(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(32),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.check_circle_outline,
            size: 48,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          Text(
            l10n.readerEndOfBook,
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildChapterMarker(
    BuildContext context, {
    required String title,
    required ChapterDisplayKind kind,
    String? chapterId,
    String? errorMessage,
    bool showSeparator = true,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        children: [
          if (showSeparator) const Divider(),
          if (showSeparator) const SizedBox(height: 8),
          Text(
            title,
            style: Theme.of(context).textTheme.labelMedium,
            textAlign: TextAlign.center,
          ),
          if (kind == ChapterDisplayKind.loading) ...[
            const SizedBox(height: 10),
            const ChapterStatusBlock(
              kind: ChapterStatusBlockKind.loading,
              compact: true,
            ),
          ],
          if (kind == ChapterDisplayKind.error) ...[
            const SizedBox(height: 10),
            ChapterStatusBlock(
              kind: ChapterStatusBlockKind.error,
              compact: true,
              message: errorMessage,
              onRetry: chapterId == null
                  ? null
                  : () => widget.loader.retryChapter(chapterId),
            ),
          ],
          const SizedBox(height: 8),
          if (showSeparator) const Divider(),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Visible position (private)
// ─────────────────────────────────────────────────────────────────────────────

class _VisiblePosition {
  final String chapterId;
  final int paragraphIndex;
  final double paragraphOffset;
  const _VisiblePosition({
    required this.chapterId,
    required this.paragraphIndex,
    required this.paragraphOffset,
  });
}

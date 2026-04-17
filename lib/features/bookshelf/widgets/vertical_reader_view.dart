import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../src/rust/api/types.dart';
import 'chapter_status_block.dart';
import 'paragraph_view.dart';
import 'reader_types.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Vertical reader view — seamless multi-chapter scroll
//
// Architecture:
//
//   CustomScrollView(center: _centerKey)
//     ├─ [reverse] prev chapter sliver  (grows upward via ValueListenableBuilder)
//     ├─ [center]  empty anchor sliver  (stable GlobalKey, scroll offset 0)
//     ├─ [forward] center chapter sliver (via ValueListenableBuilder)
//     └─ [forward] next chapter sliver  (via ValueListenableBuilder)
//
// Each slot is wrapped in a ValueListenableBuilder so that when an adjacent
// chapter finishes loading, only that slot's subtree rebuilds — the scroll
// position is unaffected because the center key anchor is stable.
//
// Chapter detection fires only on ScrollEndNotification.
// ─────────────────────────────────────────────────────────────────────────────

class VerticalReaderView extends StatefulWidget {
  const VerticalReaderView({
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
    this.initialOffset = 0,
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
  final double initialOffset;
  final ValueChanged<void Function(int, double)>? onJumpRegistered;
  final void Function(String chapterId, int paragraphIndex, ParagraphContent paragraph)? onParagraphLongPress;

  @override
  State<VerticalReaderView> createState() => _VerticalReaderViewState();
}

class _VerticalReaderViewState extends State<VerticalReaderView> {
  late ScrollController _scrollController;
  final GlobalKey _centerKey = GlobalKey();

  // Keys for reading sliver extents
  final GlobalKey _prevSliverKey = GlobalKey();
  final GlobalKey _centerSliverKey = GlobalKey();
  final GlobalKey _nextSliverKey = GlobalKey();

  bool _jumpInProgress = false;
  String? _reportedChapterId;

  static const _gap = 48.0;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _reportedChapterId = widget.centerChapterId;
    widget.onJumpRegistered?.call(jumpTo);

    if (widget.initialParagraphIndex > 0 || widget.initialOffset > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToInitial();
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant VerticalReaderView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.centerChapterId != widget.centerChapterId) {
      _reportedChapterId = widget.centerChapterId;
      _jumpInProgress = true;

      // Capture the pre-rebuild scroll state so we can translate offsets
      // into the new coordinate space (where the anchor has moved).
      final oldOffset = _scrollController.hasClients
          ? _scrollController.offset
          : 0.0;
      final oldCenterExt = _sliverExtent(_centerSliverKey);
      final oldPrevExt = _sliverExtent(_prevSliverKey);
      final wasBackward = oldWidget.prevChapterId == widget.centerChapterId;
      final wasForward = oldWidget.nextChapterId == widget.centerChapterId;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) {
          _jumpInProgress = false;
          return;
        }
        // Anchor shift in the new coordinate space. Forward slide: the old
        // center+gap region disappears from above the anchor, so every old
        // offset shrinks by (oldCenterExt + gap). Backward: the old prev+gap
        // region appears above the new anchor, so offsets grow.
        final double delta;
        if (wasForward) {
          delta = -(oldCenterExt + _gap);
        } else if (wasBackward) {
          delta = oldPrevExt + _gap;
        } else {
          _scrollController.jumpTo(0);
          _jumpInProgress = false;
          return;
        }
        final target = oldOffset + delta;
        final pos = _scrollController.position;
        // Clamp to valid range only if needed — the new extents may still be
        // settling. jumpTo will trigger another layout pass if needed.
        final clamped = target.clamp(pos.minScrollExtent, pos.maxScrollExtent);
        _scrollController.jumpTo(clamped);
        _jumpInProgress = false;
      });
    }
  }


  void _scrollToInitial() {
    if (!_scrollController.hasClients) return;
    if (widget.initialParagraphIndex <= 0) {
      _scrollController.jumpTo(widget.initialOffset.clamp(
        _scrollController.position.minScrollExtent,
        _scrollController.position.maxScrollExtent,
      ));
      return;
    }
    final avgH =
        (widget.fontScale * 16 * widget.lineHeight * 4) + LanghuanTheme.spaceMd;
    final target = widget.initialParagraphIndex * avgH + widget.initialOffset;
    _scrollController.jumpTo(target.clamp(
      _scrollController.position.minScrollExtent,
      _scrollController.position.maxScrollExtent,
    ));
  }

  /// Called externally (by content manager) to jump to a specific position.
  void jumpTo(int paragraphIndex, double offset) {
    _jumpInProgress = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) {
        _jumpInProgress = false;
        return;
      }
      if (paragraphIndex <= 0) {
        _scrollController.jumpTo(offset.clamp(
          _scrollController.position.minScrollExtent,
          _scrollController.position.maxScrollExtent,
        ));
      } else {
        final avgH = (widget.fontScale * 16 * widget.lineHeight * 4) +
            LanghuanTheme.spaceMd;
        final target = paragraphIndex * avgH + offset;
        _scrollController.jumpTo(target.clamp(
          _scrollController.position.minScrollExtent,
          _scrollController.position.maxScrollExtent,
        ));
      }
      _jumpInProgress = false;
    });
  }

  // ─ Scroll notifications ────────────────────────────────────────────────

  bool _onScrollNotification(ScrollNotification n) {
    if (_jumpInProgress || !_scrollController.hasClients) return false;

    if (n is ScrollUpdateNotification) {
      _reportOffset();
    }

    if (n is ScrollEndNotification) {
      _detectChapter();
    }

    return false;
  }

  void _reportOffset() {
    final chapterId = _reportedChapterId ?? widget.centerChapterId;
    widget.onPositionUpdate(chapterId, 0, _scrollController.offset);
  }

  // ─ Chapter detection ───────────────────────────────────────────────────

  void _detectChapter() {
    if (!_scrollController.hasClients) return;

    final vpHeight = _scrollController.position.viewportDimension;
    final center = _scrollController.offset + vpHeight / 2;

    final centerExt = _sliverExtent(_centerSliverKey);

    // Forward: center chapter (offset ≥ 0)
    if (center >= 0 && center < centerExt) {
      _reportChapter(widget.centerChapterId, center, centerExt);
      return;
    }

    // Forward: next chapter
    if (center >= centerExt && widget.nextChapterId != null) {
      final nextExt = _sliverExtent(_nextSliverKey);
      final nextStart = centerExt + _gap;
      if (center >= nextStart) {
        _reportChapter(
            widget.nextChapterId!, center - nextStart, nextExt);
        return;
      }
    }

    // Reverse: prev chapter (center < 0)
    if (center < 0 && widget.prevChapterId != null) {
      _reportChapter(widget.prevChapterId!, 0, 1);
      return;
    }

    // Fallback
    _reportChapter(widget.centerChapterId, center.clamp(0, centerExt), centerExt);
  }

  void _reportChapter(String chapterId, double offset, double extent) {
    // Note: we intentionally do NOT invoke widget.onChapterBoundary here.
    // For the vertical view, sliding the window mid-scroll causes visible
    // jumps because the sliver tree rebuilds and offsets rebase. Instead,
    // we let the user keep scrolling through prev/center/next freely and
    // only report the position. The manager only slides on explicit jumps
    // (TOC / bookmark) or when the user leaves the reader and returns.
    _reportedChapterId = chapterId;

    // Estimate paragraph index
    final state = _stateFor(chapterId);
    int paragraph = 0;
    if (state is ChapterLoaded && state.paragraphs.isNotEmpty && extent > 0) {
      final ratio = (offset / extent).clamp(0.0, 1.0);
      paragraph = (ratio * state.paragraphs.length)
          .floor()
          .clamp(0, state.paragraphs.length - 1);
    }
    widget.onPositionUpdate(chapterId, paragraph, _scrollController.offset);
  }

  ChapterLoadState _stateFor(String chapterId) {
    if (chapterId == widget.centerChapterId) return widget.centerSlot.value;
    if (chapterId == widget.prevChapterId) return widget.prevSlot.value;
    if (chapterId == widget.nextChapterId) return widget.nextSlot.value;
    return const ChapterIdle();
  }

  double _sliverExtent(GlobalKey key) {
    final ro = key.currentContext?.findRenderObject();
    if (ro is RenderSliver) return ro.geometry?.scrollExtent ?? 200;
    return 200;
  }

  // ─ Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: CustomScrollView(
        center: _centerKey,
        controller: _scrollController,
        slivers: [
          // ── Previous chapter (grows upward) ──
          if (widget.prevChapterId != null)
            ValueListenableBuilder<ChapterLoadState>(
              valueListenable: widget.prevSlot,
              builder: (_, state, _) => _buildSliver(
                key: _prevSliverKey,
                state: state,
                chapterId: widget.prevChapterId!,
                reverseChildren: true,
              ),
            ),
          if (widget.prevChapterId != null)
            const SliverToBoxAdapter(child: SizedBox(height: _gap)),

          // ── Center anchor (empty, stable key) ──
          SliverToBoxAdapter(key: _centerKey, child: const SizedBox.shrink()),

          // ── Center chapter ──
          ValueListenableBuilder<ChapterLoadState>(
            valueListenable: widget.centerSlot,
            builder: (_, state, _) => _buildSliver(
              key: _centerSliverKey,
              state: state,
              chapterId: widget.centerChapterId,
            ),
          ),

          // ── Next chapter (grows downward) ──
          if (widget.nextChapterId != null)
            const SliverToBoxAdapter(child: SizedBox(height: _gap)),
          if (widget.nextChapterId != null)
            ValueListenableBuilder<ChapterLoadState>(
              valueListenable: widget.nextSlot,
              builder: (_, state, _) => _buildSliver(
                key: _nextSliverKey,
                state: state,
                chapterId: widget.nextChapterId!,
              ),
            ),

          // ── End of book ──
          if (widget.isLastChapter) _endOfBookSliver(context),
        ],
      ),
    );
  }

  Widget _buildSliver({
    required GlobalKey key,
    required ChapterLoadState state,
    required String chapterId,
    bool reverseChildren = false,
  }) {
    return switch (state) {
      ChapterLoading() => SliverToBoxAdapter(
          key: key,
          child: const SizedBox(
            height: 200,
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      ChapterLoadError(:final message) => SliverToBoxAdapter(
          key: key,
          child: SizedBox(
            height: 300,
            child: ChapterStatusBlock(
              kind: ChapterStatusBlockKind.error,
              message: message,
              onRetry: () => widget.onRetry(chapterId),
            ),
          ),
        ),
      ChapterLoaded(:final paragraphs) => SliverPadding(
          key: key,
          padding: widget.contentPadding,
          sliver: SliverList.builder(
            itemCount: paragraphs.length,
            itemBuilder: (_, i) {
              final idx = reverseChildren ? paragraphs.length - 1 - i : i;
              return Padding(
                padding: const EdgeInsets.only(bottom: LanghuanTheme.spaceMd),
                child: ParagraphView(
                  paragraph: paragraphs[idx],
                  fontScale: widget.fontScale,
                  lineHeight: widget.lineHeight,
                  onLongPress: widget.onParagraphLongPress != null
                      ? () => widget.onParagraphLongPress!(chapterId, idx, paragraphs[idx])
                      : null,
                ),
              );
            },
          ),
        ),
      ChapterIdle() => SliverToBoxAdapter(
          key: key,
          child: const SizedBox.shrink(),
        ),
    };
  }

  Widget _endOfBookSliver(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: LanghuanTheme.spaceXl),
        child: Center(
          child: Text(
            l10n.readerEndOfBook,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),
      ),
    );
  }
}

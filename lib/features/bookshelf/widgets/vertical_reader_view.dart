import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../src/rust/api/types.dart';
import '../../feeds/feed_service.dart' show ParagraphIdStringExt;
import 'chapter_status_block.dart';
import 'chapter_store.dart';
import 'paragraph_view.dart';
import 'reader_types.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Vertical reader view — virtual infinite scroll
//
// Uses CustomScrollView with a center key for true bidirectional scrolling.
// Two SliverList.builder instances grow from the anchor in opposite
// directions, mapping virtual indices → chapter paragraphs via ChapterStore.
//
// Architecture:
//
//   CustomScrollView(center: _centerKey)
//     ├─ [reverse] SliverList.builder  — paragraphs from earlier chapters
//     ├─ [center]  empty anchor        — stable key, scroll offset 0
//     └─ [forward] SliverList.builder  — paragraphs from active + later chapters
//
// No scroll offset correction is ever needed — the anchor is stable and
// chapters simply grow outward in both directions.
// ─────────────────────────────────────────────────────────────────────────────

class VerticalReaderView extends StatefulWidget {
  const VerticalReaderView({
    super.key,
    required this.store,
    required this.activeChapterSeq,
    required this.fontScale,
    required this.lineHeight,
    required this.contentPadding,
    required this.onPositionUpdate,
    required this.onRetry,
    this.initialParagraphId = '',
    this.initialOffset = 0,
    this.onJumpRegistered,
    this.onParagraphLongPress,
    this.selectedChapterId,
    this.selectedParagraphId,
  });

  final ChapterStore store;
  final int activeChapterSeq;
  final double fontScale;
  final double lineHeight;
  final EdgeInsets contentPadding;
  final void Function(String chapterId, String paragraphId, double offset)
      onPositionUpdate;
  final void Function(String chapterId) onRetry;
  final String initialParagraphId;
  final double initialOffset;
  final ValueChanged<void Function(String, double)>? onJumpRegistered;
  final void Function(
    String chapterId,
    String paragraphId,
    ParagraphContent paragraph,
    Rect globalRect,
  )? onParagraphLongPress;
  final String? selectedChapterId;
  final String? selectedParagraphId;

  @override
  State<VerticalReaderView> createState() => _VerticalReaderViewState();
}

class _VerticalReaderViewState extends State<VerticalReaderView> {
  late ScrollController _scrollController;
  final GlobalKey _centerKey = GlobalKey();
  final GlobalKey _scrollViewKey = GlobalKey();

  bool _jumpInProgress = false;
  String _scrollTargetParagraphId = '';
  final GlobalKey _jumpTargetKey = GlobalKey();
  int _ensureRetries = 0;
  static const _maxEnsureRetries = 10;

  static const _chapterGap = 48.0;

  final Map<int, GlobalKey> _chapterKeys = {};

  GlobalKey _chapterKey(int seq) {
    return _chapterKeys.putIfAbsent(seq, () => GlobalKey());
  }

  List<_ResolvedItem> _forwardItems = [];
  List<_ResolvedItem> _reverseItems = [];

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    widget.onJumpRegistered?.call(jumpTo);
    widget.store.addListener(_onStoreChanged);

    _rebuildItems();
    _scheduleInitialScroll();
  }

  @override
  void didUpdateWidget(covariant VerticalReaderView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      oldWidget.store.removeListener(_onStoreChanged);
      widget.store.addListener(_onStoreChanged);
    }
    _rebuildItems();
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStoreChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _onStoreChanged() {
    if (!mounted) return;
    _rebuildItems();
    setState(() {});
  }

  void _scheduleInitialScroll() {
    if (widget.initialParagraphId.isNotEmpty) {
      _scrollTargetParagraphId = widget.initialParagraphId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _ensureTargetVisible();
      });
    } else if (widget.initialOffset > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToOffset(widget.initialOffset);
      });
    }
  }

  void _scrollToOffset(double offset) {
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(offset.clamp(
      _scrollController.position.minScrollExtent,
      _scrollController.position.maxScrollExtent,
    ));
  }

  void _ensureTargetVisible() {
    if (!mounted || !_scrollController.hasClients) return;
    final ctx = _jumpTargetKey.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.0,
        duration: Duration.zero,
      );
      setState(() => _scrollTargetParagraphId = '');
      _jumpInProgress = false;
      _ensureRetries = 0;
      return;
    }

    if (++_ensureRetries > _maxEnsureRetries) {
      setState(() => _scrollTargetParagraphId = '');
      _jumpInProgress = false;
      _ensureRetries = 0;
      return;
    }

    // Estimate scroll position to bring the target into the builder's range.
    final paras = widget.store.paragraphsAt(widget.activeChapterSeq);
    if (paras != null && paras.isNotEmpty && _scrollTargetParagraphId.isNotEmpty) {
      // Find the index of the target paragraph by ID
      int targetIdx = paras.indexWhere((p) => p.id.toStringValue() == _scrollTargetParagraphId);
      if (targetIdx >= 0) {
        final vpHeight = _scrollController.position.viewportDimension;
        final estimatedItemHeight = vpHeight / 4;
        final target = targetIdx * estimatedItemHeight;
        _scrollController.jumpTo(target.clamp(
          _scrollController.position.minScrollExtent,
          _scrollController.position.maxScrollExtent,
        ));
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureTargetVisible();
    });
  }

  void jumpTo(String paragraphId, double offset) {
    _jumpInProgress = true;
    _ensureRetries = 0;
    if (paragraphId.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToOffset(offset);
        _jumpInProgress = false;
      });
      return;
    }
    _scrollTargetParagraphId = paragraphId;
    _rebuildItems();
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureTargetVisible();
    });
  }

  // ─ Precompute item lists ──────────────────────────────────────────────

  void _rebuildItems() {
    _forwardItems = _buildForwardItems();
    _reverseItems = _buildReverseItems();

    final activeSeqs = <int>{};
    for (final item in _forwardItems) {
      if (item.kind == _ResolvedItemKind.paragraph && item.localIndex == 0) {
        activeSeqs.add(item.chapterSeq!);
      }
    }
    for (final item in _reverseItems) {
      if (item.kind == _ResolvedItemKind.paragraph && item.localIndex == 0) {
        activeSeqs.add(item.chapterSeq!);
      }
    }
    _chapterKeys.removeWhere((seq, _) => !activeSeqs.contains(seq));
  }

  static const _loadRadius = 2;

  List<_ResolvedItem> _buildForwardItems() {
    final store = widget.store;
    final items = <_ResolvedItem>[];
    int? seq = widget.activeChapterSeq;

    while (seq != null && seq <= store.maxSeq) {
      final state = store.stateAt(seq);

      if (state is ChapterLoadError) {
        items.add(_ResolvedItem.error(seq, state.message));
        return items;
      }

      final paras = store.paragraphsAt(seq);
      if (paras == null) {
        if (store.chapterDistance(seq, store.activeSeq) <= _loadRadius) {
          store.ensureLoaded(seq);
        }
        items.add(_ResolvedItem.loading(seq));
        return items;
      }

      final chapterId = store.idAt(seq)!;
      for (int i = 0; i < paras.length; i++) {
        items.add(_ResolvedItem.paragraph(seq, i, paras[i], chapterId));
      }

      final next = store.nextSeq(seq);
      if (next != null) {
        items.add(_ResolvedItem.gap());
      }

      seq = next;
    }

    items.add(_ResolvedItem.endOfBook());
    return items;
  }

  List<_ResolvedItem> _buildReverseItems() {
    final store = widget.store;
    final items = <_ResolvedItem>[];
    int? seq = store.prevSeq(widget.activeChapterSeq);

    if (seq == null) return items;

    while (seq != null) {
      items.add(_ResolvedItem.gap());

      final state = store.stateAt(seq);
      if (state is ChapterLoadError) {
        items.add(_ResolvedItem.error(seq, state.message));
        return items;
      }

      final paras = store.paragraphsAt(seq);
      if (paras == null) {
        if (store.chapterDistance(seq, store.activeSeq) <= _loadRadius) {
          store.ensureLoaded(seq);
        }
        items.add(_ResolvedItem.loading(seq));
        return items;
      }

      final chapterId = store.idAt(seq)!;
      for (int i = paras.length - 1; i >= 0; i--) {
        items.add(_ResolvedItem.paragraph(seq, i, paras[i], chapterId));
      }

      seq = store.prevSeq(seq);
    }

    return items;
  }

  // ─ Scroll notifications & position tracking ───────────────────────────

  bool _onScrollNotification(ScrollNotification n) {
    if (_jumpInProgress || !_scrollController.hasClients) return false;

    if (n is ScrollUpdateNotification || n is ScrollEndNotification) {
      _reportPosition();
    }

    return false;
  }

  void _reportPosition() {
    if (!_scrollController.hasClients) return;

    final offset = _scrollController.offset;
    final vpHeight = _scrollController.position.viewportDimension;

    final store = widget.store;

    final chapterSeqs = <int>{};
    for (final item in _forwardItems) {
      if (item.kind == _ResolvedItemKind.paragraph && item.localIndex == 0) {
        chapterSeqs.add(item.chapterSeq!);
      }
    }
    for (final item in _reverseItems) {
      if (item.kind == _ResolvedItemKind.paragraph && item.localIndex == 0) {
        chapterSeqs.add(item.chapterSeq!);
      }
    }

    if (chapterSeqs.isEmpty) {
      _reportFallback(store, offset);
      return;
    }

    final scrollContext = _scrollViewKey.currentContext;
    if (scrollContext == null) {
      _reportFallback(store, offset);
      return;
    }
    final scrollBox = scrollContext.findRenderObject();
    if (scrollBox is! RenderBox || !scrollBox.attached) {
      _reportFallback(store, offset);
      return;
    }

    final vpTopGlobal = scrollBox.localToGlobal(Offset.zero).dy;
    final vpCenterGlobal = vpTopGlobal + vpHeight / 2;

    int? bestSeq;
    double bestY = double.negativeInfinity;

    for (final seq in chapterSeqs) {
      final key = _chapterKeys[seq];
      if (key == null) continue;
      final ctx = key.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject();
      if (box is! RenderBox || !box.attached) continue;

      final topGlobal = box.localToGlobal(Offset.zero).dy;

      if (topGlobal <= vpCenterGlobal && topGlobal > bestY) {
        bestY = topGlobal;
        bestSeq = seq;
      }
    }

    if (bestSeq == null) {
      double closest = double.infinity;
      for (final seq in chapterSeqs) {
        final key = _chapterKeys[seq];
        if (key == null) continue;
        final ctx = key.currentContext;
        if (ctx == null) continue;
        final box = ctx.findRenderObject();
        if (box is! RenderBox || !box.attached) continue;
        final topGlobal = box.localToGlobal(Offset.zero).dy;
        final dist = (topGlobal - vpCenterGlobal).abs();
        if (dist < closest) {
          closest = dist;
          bestSeq = seq;
        }
      }
    }

    if (bestSeq == null) {
      _reportFallback(store, offset);
      return;
    }

    final chapterId = store.idAt(bestSeq);
    if (chapterId == null) {
      _reportFallback(store, offset);
      return;
    }

    final paras = store.paragraphsAt(bestSeq);
    String paragraphId = '';
    if (paras != null && paras.isNotEmpty) {
      int paraIdx = 0;
      final chapterKey = _chapterKeys[bestSeq];
      if (chapterKey != null) {
        final ctx = chapterKey.currentContext;
        if (ctx != null) {
          final box = ctx.findRenderObject();
          if (box is RenderBox && box.attached) {
            final chapterTopGlobal = box.localToGlobal(Offset.zero).dy;
            final distPastStart = vpCenterGlobal - chapterTopGlobal;

            final nextSeq = store.nextSeq(bestSeq);
            double chapterHeight = vpHeight;
            if (nextSeq != null) {
              final nextKey = _chapterKeys[nextSeq];
              if (nextKey != null) {
                final nextCtx = nextKey.currentContext;
                if (nextCtx != null) {
                  final nextBox = nextCtx.findRenderObject();
                  if (nextBox is RenderBox && nextBox.attached) {
                    chapterHeight = nextBox.localToGlobal(Offset.zero).dy -
                        chapterTopGlobal -
                        _chapterGap;
                    if (chapterHeight <= 0) chapterHeight = vpHeight;
                  }
                }
              }
            }

            final ratio = (distPastStart / chapterHeight).clamp(0.0, 1.0);
            paraIdx = (ratio * paras.length).floor().clamp(0, paras.length - 1);
          }
        }
      }
      paragraphId = paras[paraIdx].id.toStringValue();
    }

    store.setActive(bestSeq);
    widget.onPositionUpdate(chapterId, paragraphId, offset);
  }

  void _reportFallback(ChapterStore store, double offset) {
    final fallbackId = store.idAt(widget.activeChapterSeq);
    if (fallbackId != null) {
      widget.onPositionUpdate(fallbackId, '', offset);
    }
  }

  // ─ Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: CustomScrollView(
        key: _scrollViewKey,
        center: _centerKey,
        controller: _scrollController,
        slivers: [
          // ── Reverse sliver (earlier chapters) ──
          SliverList.builder(
            itemCount: _reverseItems.length,
            itemBuilder: (context, index) {
              return _buildResolvedItem(_reverseItems[index]);
            },
          ),

          // ── Center anchor (empty, stable key) ──
          SliverToBoxAdapter(
            key: _centerKey,
            child: const SizedBox.shrink(),
          ),

          // ── Forward sliver (active + later chapters) ──
          SliverList.builder(
            itemCount: _forwardItems.length,
            itemBuilder: (context, index) {
              return _buildResolvedItem(_forwardItems[index]);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildResolvedItem(_ResolvedItem item) {
    return switch (item.kind) {
      _ResolvedItemKind.paragraph => _buildParagraph(item),
      _ResolvedItemKind.gap => const SizedBox(height: _chapterGap),
      _ResolvedItemKind.loading => _buildLoading(item),
      _ResolvedItemKind.error => SizedBox(
          height: 300,
          child: ChapterStatusBlock(
            kind: ChapterStatusBlockKind.error,
            message: item.errorMessage,
            onRetry: () {
              final chapterId = widget.store.idAt(item.chapterSeq!);
              if (chapterId != null) widget.onRetry(chapterId);
            },
          ),
        ),
      _ResolvedItemKind.endOfBook => _buildEndOfBook(context),
    };
  }

  Widget _buildLoading(_ResolvedItem item) {
    return const SizedBox(
      height: 200,
      child: Center(child: CircularProgressIndicator()),
    );
  }

  Widget _buildParagraph(_ResolvedItem item) {
    final chapterId = item.chapterId!;
    final localIdx = item.localIndex!;
    final paragraph = item.paragraph!;
    final seq = item.chapterSeq!;
    final paragraphId = paragraph.id.toStringValue();

    final isSelected = widget.selectedChapterId == chapterId &&
        widget.selectedParagraphId == paragraphId;

    final isJumpTarget =
        chapterId == widget.store.idAt(widget.activeChapterSeq) &&
            paragraphId == _scrollTargetParagraphId;

    Key? widgetKey;
    if (isJumpTarget) {
      widgetKey = _jumpTargetKey;
    } else if (localIdx == 0) {
      widgetKey = _chapterKey(seq);
    }

    return Padding(
      key: widgetKey,
      padding: EdgeInsets.only(
        left: widget.contentPadding.left,
        right: widget.contentPadding.right,
        top: seq == widget.activeChapterSeq && localIdx == 0
            ? widget.contentPadding.top
            : 0,
        bottom: LanghuanTheme.spaceMd,
      ),
      child: ParagraphView(
        paragraph: paragraph,
        fontScale: widget.fontScale,
        lineHeight: widget.lineHeight,
        selected: isSelected,
        onLongPress: widget.onParagraphLongPress != null
            ? (rect) => widget.onParagraphLongPress!(
                chapterId, paragraphId, paragraph, rect)
            : null,
      ),
    );
  }

  Widget _buildEndOfBook(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: LanghuanTheme.spaceXl),
      child: Center(
        child: Text(
          l10n.readerEndOfBook,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Resolved item — internal type for the virtual index → widget mapping
// ─────────────────────────────────────────────────────────────────────────────

enum _ResolvedItemKind { paragraph, gap, loading, error, endOfBook }

class _ResolvedItem {
  _ResolvedItem._({
    required this.kind,
    this.chapterSeq,
    this.localIndex,
    this.paragraph,
    this.chapterId,
    this.errorMessage,
  });

  factory _ResolvedItem.paragraph(
    int seq,
    int localIndex,
    ParagraphContent paragraph,
    String chapterId,
  ) =>
      _ResolvedItem._(
        kind: _ResolvedItemKind.paragraph,
        chapterSeq: seq,
        localIndex: localIndex,
        paragraph: paragraph,
        chapterId: chapterId,
      );

  factory _ResolvedItem.gap() => _ResolvedItem._(
        kind: _ResolvedItemKind.gap,
      );

  factory _ResolvedItem.loading(int seq) => _ResolvedItem._(
        kind: _ResolvedItemKind.loading,
        chapterSeq: seq,
      );

  factory _ResolvedItem.error(int seq, String message) => _ResolvedItem._(
        kind: _ResolvedItemKind.error,
        chapterSeq: seq,
        errorMessage: message,
      );

  factory _ResolvedItem.endOfBook() => _ResolvedItem._(
        kind: _ResolvedItemKind.endOfBook,
      );

  final _ResolvedItemKind kind;
  final int? chapterSeq;
  final int? localIndex;
  final ParagraphContent? paragraph;
  final String? chapterId;
  final String? errorMessage;
}

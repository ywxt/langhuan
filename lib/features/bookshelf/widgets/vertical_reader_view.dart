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
// VerticalReaderView
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

  /// Key for the center (forward) sliver — placed on the center chapter's
  /// own content sliver so that additions above/below don't shift the
  /// viewport.
  final _centerSliverKey = GlobalKey();

  /// GlobalKeys for content paragraphs — used for scroll-to and detection.
  final Map<String, GlobalKey> _paragraphKeys = {};

  bool _needsInitialScroll = true;
  bool _suppressDetection = false;
  String? _visibleChapterId;
  _VisiblePosition? _pendingPosition;

  /// The last position we reported upward via _commitPosition.
  /// When the parent rebuilds us with these exact values, didUpdateWidget
  /// knows it is just an echo and must NOT treat it as an external jump.
  /// A genuinely different position (e.g. button press) will not match.
  ({String chapterId, int paragraphIndex, double paragraphOffset})?
  _lastReportedPosition;

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

    // Ignore position changes that we ourselves reported upward via
    // _commitPosition.  The parent just echoed our values back.
    // A genuinely different position (e.g. prev/next chapter button)
    // will NOT match and will proceed to _jumpToChapter.
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

  // ─ Chapter jump (from TOC / bottom bar) ────────────────────────────────

  void _jumpToChapter(String chapterId, int paragraph, double offset) {
    _pendingPosition = null;
    _centerChapterId = chapterId;

    // Replace scroll controller so the new center chapter starts at offset 0.
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _scrollController = ScrollController()..addListener(_onScroll);

    if (paragraph > 0 || offset > 0) {
      _scrollToChapterParagraph(chapterId, paragraph, offset);
    }
    if (mounted) setState(() {});
  }

  // ─ Scroll detection ────────────────────────────────────────────────────

  void _onScroll() {
    if (!_scrollController.hasClients || _suppressDetection) return;
    final pos = _detectVisiblePosition();
    if (pos != null) _pendingPosition = pos;
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

      // Item is at least partially visible (top above viewport bottom,
      // bottom below viewport top).
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

  // ─ Scroll to a specific paragraph ──────────────────────────────────────

  /// Maximum number of frames to retry when the target paragraph widget
  /// has not been laid out yet (lazy SliverList).
  static const _kMaxScrollRetries = 10;

  void _scrollToChapterParagraph(
    String chapterId,
    int paragraphIndex,
    double paragraphOffset, {
    int attempt = 0,
  }) {
    // Suppress scroll detection for the entire jump sequence (including
    // retries) so intermediate positions are not committed.
    _suppressDetection = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _suppressDetection = false;
        return;
      }

      final keyStr = '$chapterId:$paragraphIndex';
      final key = _paragraphKeys[keyStr];

      if (key == null || key.currentContext == null) {
        if (attempt < _kMaxScrollRetries) {
          // The target paragraph hasn't been built yet by the lazy
          // SliverList.  Scroll toward the end of the currently-built
          // content so that the framework lays out more children, then
          // retry next frame.
          if (_scrollController.hasClients) {
            final pos = _scrollController.position;
            final jump = (pos.maxScrollExtent).clamp(
              pos.minScrollExtent,
              pos.maxScrollExtent,
            );
            if (jump > _scrollController.offset) {
              _scrollController.jumpTo(jump);
            }
          }
          _scrollToChapterParagraph(
            chapterId,
            paragraphIndex,
            paragraphOffset,
            attempt: attempt + 1,
          );
        } else {
          // After max retries, give up — re-enable detection.
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

  // ─ Key management ──────────────────────────────────────────────────────

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

  // ─ Build ───────────────────────────────────────────────────────────────

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

    // Slots before center (reversed for upward growth).
    final beforeSlots = slots.sublist(0, centerIdx).reversed.toList();
    // Slots from center onward.
    final forwardSlots = slots.sublist(centerIdx);

    // Flatten each group into a list of _FlatItem descriptors.
    final beforeItems = _flattenSlots(
      beforeSlots,
      firstIsTop: true,
      isBeforeList: true,
    );
    final forwardItems = _flattenSlots(
      forwardSlots,
      firstIsTop: beforeSlots.isEmpty,
    );

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

    final hPadding = EdgeInsets.symmetric(
      horizontal: widget.contentPadding.left,
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
          // ── Before-center: single stable SliverList (grows upward) ─
          SliverPadding(
            padding: EdgeInsets.only(
              top: widget.contentPadding.top,
              left: hPadding.left,
              right: hPadding.right,
            ),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => _buildFlatItem(context, beforeItems, index),
                childCount: beforeItems.length,
                findChildIndexCallback: (Key key) =>
                    _findFlatChildIndex(key, beforeItems),
              ),
            ),
          ),

          // ── Forward: single stable SliverList (grows downward) ─────
          SliverPadding(
            key: _centerSliverKey,
            padding: EdgeInsets.only(
              left: hPadding.left,
              right: hPadding.right,
            ),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) =>
                    _buildFlatItem(context, forwardItems, index),
                childCount: forwardItems.length,
                findChildIndexCallback: (Key key) =>
                    _findFlatChildIndex(key, forwardItems),
              ),
            ),
          ),

          // ── Bottom boundary ────────────────────────────────────────
          SliverPadding(
            padding: EdgeInsets.only(bottom: widget.contentPadding.bottom),
            sliver: SliverToBoxAdapter(child: _buildBottomBoundary(context)),
          ),
        ],
      ),
    );
  }

  // ─ Flat item model ─────────────────────────────────────────────────────

  /// Flatten a list of [ChapterSlot]s into a flat list of items suitable
  /// for a single [SliverList].  Each chapter contributes:
  ///   - a chapter marker (separator / loading / error)
  ///   - if ready: one item per paragraph
  ///
  /// [firstIsTop] indicates whether the first slot in visual order (the
  /// topmost chapter) is in this group.
  /// For the before-list (reversed), the topmost chapter is the last element.
  /// For the forward-list, the topmost chapter is the first element.
  /// [isBeforeList] distinguishes the two cases.
  List<_FlatItem> _flattenSlots(
    List<ChapterSlot> slots, {
    required bool firstIsTop,
    bool isBeforeList = false,
  }) {
    final items = <_FlatItem>[];
    for (int si = 0; si < slots.length; si++) {
      final slot = slots[si];
      // The topmost chapter in the entire scroll view needs no separator.
      final bool isFirst;
      if (isBeforeList) {
        // Before-list is reversed: last element is the topmost.
        isFirst = firstIsTop && si == slots.length - 1;
      } else {
        // Forward-list: first element is the topmost.
        isFirst = firstIsTop && si == 0;
      }

      if (slot.isLoading) {
        items.add(
          _FlatItem.marker(
            slot: slot,
            kind: ChapterDisplayKind.loading,
            showSeparator: !isFirst,
          ),
        );
        continue;
      }

      if (slot.isError) {
        items.add(
          _FlatItem.marker(
            slot: slot,
            kind: ChapterDisplayKind.error,
            showSeparator: !isFirst,
          ),
        );
        continue;
      }

      // Ready chapter.
      if (!isFirst) {
        items.add(
          _FlatItem.marker(
            slot: slot,
            kind: ChapterDisplayKind.success,
            showSeparator: true,
          ),
        );
      }
      final paragraphs = slot.paragraphs ?? const <ParagraphContent>[];
      for (int pi = 0; pi < paragraphs.length; pi++) {
        items.add(
          _FlatItem.paragraph(
            slot: slot,
            paragraphIndex: pi,
            content: paragraphs[pi],
          ),
        );
      }
    }
    return items;
  }

  Widget _buildFlatItem(
    BuildContext context,
    List<_FlatItem> items,
    int index,
  ) {
    if (index < 0 || index >= items.length) return const SizedBox.shrink();
    final item = items[index];

    if (item.isMarker) {
      String title;
      if (item.kind == ChapterDisplayKind.success) {
        final paragraphs = item.slot.paragraphs ?? const <ParagraphContent>[];
        title = _resolveTitle(paragraphs, item.slot);
      } else {
        title = _slotTitle(item.slot);
      }
      return _buildChapterMarker(
        context,
        title: title,
        kind: item.kind!,
        chapterId: item.slot.chapterId,
        errorMessage: item.slot.errorMessage,
        showSeparator: item.showSeparator,
      );
    }

    // Paragraph item.
    final gk = _getOrCreateKey(item.slot.chapterId, item.paragraphIndex!);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: ParagraphView(key: gk, item: item.content!),
    );
  }

  int? _findFlatChildIndex(Key key, List<_FlatItem> items) {
    if (key is! GlobalKey) return null;
    for (final entry in _paragraphKeys.entries) {
      if (entry.value != key) continue;
      final parts = entry.key.split(':');
      if (parts.length != 2) continue;
      final chId = parts[0];
      final pIdx = int.tryParse(parts[1]);
      if (pIdx == null) continue;
      for (int i = 0; i < items.length; i++) {
        final item = items[i];
        if (!item.isMarker &&
            item.slot.chapterId == chId &&
            item.paragraphIndex == pIdx) {
          return i;
        }
      }
    }
    return null;
  }

  // ─ Helpers ─────────────────────────────────────────────────────────────

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

  // ─ Boundary widgets ───────────────────────────────────────────────────

  Widget _buildBottomBoundary(BuildContext context) {
    final isTrueBookEnd =
        widget.loader.isAtBookEnd && !widget.loader.hasNewerUnloaded;
    if (isTrueBookEnd) return _buildEndOfBookBlock(context);

    final slots = widget.loader.slots;
    for (int i = slots.length - 1; i >= 0; i--) {
      if (slots[i].isError) {
        return ChapterStatusBlock(
          kind: ChapterStatusBlockKind.error,
          compact: false,
          padding: const EdgeInsets.all(32),
          message: slots[i].errorMessage,
          onRetry: () => widget.loader.retryChapter(slots[i].chapterId),
        );
      }
      if (slots[i].isReady) break;
    }
    return const ChapterStatusBlock(
      kind: ChapterStatusBlockKind.loading,
      compact: false,
      padding: EdgeInsets.all(32),
    );
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

// ─────────────────────────────────────────────────────────────────────────────
// Scroll anchor — snapshot of a paragraph's viewport-relative position
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// Flat item — descriptor for a single row in the flattened SliverList
// ─────────────────────────────────────────────────────────────────────────────

class _FlatItem {
  final ChapterSlot slot;

  // Marker fields
  final bool isMarker;
  final ChapterDisplayKind? kind;
  final bool showSeparator;

  // Paragraph fields
  final int? paragraphIndex;
  final ParagraphContent? content;

  const _FlatItem._({
    required this.slot,
    required this.isMarker,
    this.kind,
    this.showSeparator = false,
    this.paragraphIndex,
    this.content,
  });

  factory _FlatItem.marker({
    required ChapterSlot slot,
    required ChapterDisplayKind kind,
    required bool showSeparator,
  }) => _FlatItem._(
    slot: slot,
    isMarker: true,
    kind: kind,
    showSeparator: showSeparator,
  );

  factory _FlatItem.paragraph({
    required ChapterSlot slot,
    required int paragraphIndex,
    required ParagraphContent content,
  }) => _FlatItem._(
    slot: slot,
    isMarker: false,
    paragraphIndex: paragraphIndex,
    content: content,
  );
}

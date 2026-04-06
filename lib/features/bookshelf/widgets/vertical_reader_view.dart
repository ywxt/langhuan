import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../l10n/app_localizations.dart';
import '../../../src/bindings/signals/signals.dart';
import 'chapter_loader.dart';
import 'chapter_status_block.dart';
import 'paragraph_view.dart';
import 'reader_display_mapper.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Vertical item model
// ─────────────────────────────────────────────────────────────────────────────

enum VerticalItemType { topBoundary, chapterMarker, content, bottomBoundary }

class VerticalItem {
  final VerticalItemType type;
  final ParagraphContent? content;
  final String? chapterTitle;
  final String? chapterId;
  final ChapterDisplayKind? chapterKind;
  final String? errorMessage;
  final int paragraphIndexInChapter;

  const VerticalItem({
    required this.type,
    this.content,
    this.chapterTitle,
    this.chapterId,
    this.chapterKind,
    this.errorMessage,
    this.paragraphIndexInChapter = 0,
  });

  /// Stable key for this item, used as ValueKey to maintain scroll position.
  String get stableKey {
    switch (type) {
      case VerticalItemType.topBoundary:
        return '__top_boundary__';
      case VerticalItemType.bottomBoundary:
        return '__bottom_boundary__';
      case VerticalItemType.chapterMarker:
        return '__marker_${chapterId ?? "unknown"}__';
      case VerticalItemType.content:
        return '${chapterId ?? "unknown"}:$paragraphIndexInChapter';
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// VerticalReaderView
// ─────────────────────────────────────────────────────────────────────────────

class VerticalReaderView extends StatefulWidget {
  const VerticalReaderView({
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
  State<VerticalReaderView> createState() => _VerticalReaderViewState();
}

class _VerticalReaderViewState extends State<VerticalReaderView> {
  late final ScrollController _scrollController;

  List<VerticalItem> _items = [];
  final Map<String, GlobalKey> _itemKeys = {};

  bool _dirty = true;
  bool _suppressDetection = false;
  bool _needsInitialScroll = true;
  String? _visibleChapterId;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController()..addListener(_onScroll);
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
      _dirty = true;
    }
  }

  void _onLoaderChanged() {
    if (mounted) setState(() => _dirty = true);
  }

  // ─ Item list rebuild ─────────────────────────────────────────────────────

  void _syncItems() {
    _dirty = false;

    final anchor = _needsInitialScroll ? null : _captureViewportAnchor();

    final l10n = AppLocalizations.of(context);
    final slots = widget.loader.slots;
    final entries = buildChapterDisplayEntries(slots: slots, l10n: l10n);
    final items = <VerticalItem>[];

    for (int i = 0; i < entries.length; i++) {
      final entry = entries[i];

      if (entry.kind != ChapterDisplayKind.success) {
        items.add(
          VerticalItem(
            type: VerticalItemType.chapterMarker,
            chapterTitle: entry.title,
            chapterId: entry.chapterId,
            chapterKind: entry.kind,
            errorMessage: entry.errorMessage,
          ),
        );
        continue;
      }

      // Chapter separator (not before first).
      if (i > 0) {
        items.add(
          VerticalItem(
            type: VerticalItemType.chapterMarker,
            chapterTitle: entry.title,
            chapterId: entry.chapterId,
            chapterKind: ChapterDisplayKind.success,
          ),
        );
      }

      for (int pIdx = 0; pIdx < entry.content.length; pIdx++) {
        items.add(
          VerticalItem(
            type: VerticalItemType.content,
            content: entry.content[pIdx],
            chapterId: entry.chapterId,
            paragraphIndexInChapter: pIdx,
          ),
        );
      }
    }

    // Bottom boundary.
    if (slots.isNotEmpty) {
      items.add(const VerticalItem(type: VerticalItemType.bottomBoundary));
    }

    _items = items;
    _pruneKeys();

    // Restore position.
    if (_needsInitialScroll) {
      _needsInitialScroll = false;
      _scrollToChapterParagraph(
        widget.initialChapterId,
        widget.initialParagraphIndex,
      );
    } else if (anchor != null) {
      _restoreViewportAnchor(anchor);
    }
  }

  // ─ Scroll listener ───────────────────────────────────────────────────────

  void _onScroll() {
    if (!_scrollController.hasClients || _suppressDetection) return;
    _detectVisibleChapter();

    // Preload if approaching boundaries.
    final pos = _scrollController.position;
    widget.loader.preloadIfNeeded(
      approachingEnd:
          pos.maxScrollExtent > 0 && (pos.maxScrollExtent - pos.pixels) < 500,
      approachingStart: pos.pixels < 500,
    );
  }

  void _detectVisibleChapter() {
    final anchor = _captureViewportAnchor();
    if (anchor == null) return;

    if (_visibleChapterId != anchor.chapterId) {
      _visibleChapterId = anchor.chapterId;
      widget.loader.setCurrentChapter(anchor.chapterId);
      widget.onChapterChanged(anchor.chapterId);
    }
    widget.onParagraphChanged(anchor.paragraphIndex);
  }

  // ─ Viewport anchor ──────────────────────────────────────────────────────

  _ViewportAnchor? _captureViewportAnchor() {
    if (!_scrollController.hasClients || _items.isEmpty) return null;

    _ViewportAnchor? best;
    double bestDistance = double.infinity;

    for (final item in _items) {
      if (item.type != VerticalItemType.content || item.chapterId == null) {
        continue;
      }

      final key = _itemKeys[item.stableKey];
      if (key?.currentContext == null) continue;

      final renderObject = key!.currentContext!.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.attached) continue;

      final viewport = RenderAbstractViewport.of(renderObject);
      final revealedOffset = viewport.getOffsetToReveal(renderObject, 0.0);
      final relativeOffset = revealedOffset.offset - _scrollController.offset;

      if (relativeOffset > -renderObject.size.height && relativeOffset <= 50) {
        final dist = relativeOffset.abs();
        if (dist < bestDistance) {
          bestDistance = dist;
          best = _ViewportAnchor(
            chapterId: item.chapterId!,
            paragraphIndex: item.paragraphIndexInChapter,
          );
        }
      }
    }

    return best;
  }

  void _restoreViewportAnchor(_ViewportAnchor anchor) {
    _scrollToChapterParagraph(anchor.chapterId, anchor.paragraphIndex);
  }

  void _scrollToChapterParagraph(String chapterId, int paragraphIndex) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final keyStr = '$chapterId:$paragraphIndex';
      var key = _itemKeys[keyStr];
      if ((key == null || key.currentContext == null) && paragraphIndex > 0) {
        key = _itemKeys['$chapterId:0'];
      }
      if (key?.currentContext == null) return;

      _suppressDetection = true;
      Scrollable.ensureVisible(
        key!.currentContext!,
        alignment: 0.0,
        duration: Duration.zero,
      ).then((_) {
        if (mounted) {
          _suppressDetection = false;
          _detectVisibleChapter();
        }
      });
    });
  }

  // ─ Key management ────────────────────────────────────────────────────────

  GlobalKey _getOrCreateKey(String stableKey) {
    return _itemKeys.putIfAbsent(stableKey, () => GlobalKey());
  }

  void _pruneKeys() {
    final validKeys = <String>{};
    for (final item in _items) {
      if (item.type == VerticalItemType.content && item.chapterId != null) {
        validKeys.add(item.stableKey);
      }
    }
    _itemKeys.removeWhere((key, _) => !validKeys.contains(key));
  }

  // ─ Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_dirty) _syncItems();

    if (_items.isEmpty) {
      if (widget.loader.slots.isEmpty) {
        return const Center(
          child: ChapterStatusBlock(
            kind: ChapterStatusBlockKind.loading,
            compact: false,
            padding: EdgeInsets.all(32),
          ),
        );
      }
    }

    return ListView.builder(
      controller: _scrollController,
      padding: widget.contentPadding,
      itemCount: _items.length,
      itemBuilder: (context, index) {
        final item = _items[index];

        switch (item.type) {
          case VerticalItemType.topBoundary:
            return const SizedBox.shrink();
          case VerticalItemType.bottomBoundary:
            return _buildBottomBoundary(context);
          case VerticalItemType.chapterMarker:
            return _buildChapterMarker(
              context,
              title: item.chapterTitle ?? '',
              chapterId: item.chapterId,
              kind: item.chapterKind ?? ChapterDisplayKind.success,
              errorMessage: item.errorMessage,
            );
          case VerticalItemType.content:
            if (item.content == null) return const SizedBox.shrink();
            final key = _getOrCreateKey(item.stableKey);
            return ParagraphView(key: key, item: item.content!);
        }
      },
    );
  }

  // ─ Boundary widgets ─────────────────────────────────────────────────────

  Widget _buildBottomBoundary(BuildContext context) {
    if (widget.loader.isAtBookEnd) return _buildEndOfBookBlock(context);

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
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        children: [
          const Divider(),
          const SizedBox(height: 8),
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
          const Divider(),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Viewport anchor (private)
// ─────────────────────────────────────────────────────────────────────────────

class _ViewportAnchor {
  final String chapterId;
  final int paragraphIndex;
  const _ViewportAnchor({
    required this.chapterId,
    required this.paragraphIndex,
  });
}

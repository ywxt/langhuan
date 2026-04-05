import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/cover_image.dart';
import '../../../src/bindings/signals/signals.dart';
import 'base_reader_view.dart';
import 'chapter_window_manager.dart';
import 'paragraph_view.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Models
// ─────────────────────────────────────────────────────────────────────────────

/// Represents one item in the vertical scroll view.
enum _VerticalItemType {
  topBoundary,
  chapterSeparator,
  content,
  bottomBoundary,
}

class _VerticalItem {
  final _VerticalItemType type;
  final ParagraphContent? content;
  final String? chapterTitle;
  final String? chapterId;

  const _VerticalItem({
    required this.type,
    this.content,
    this.chapterTitle,
    this.chapterId,
  });
}

/// Maps a range of item indices to a chapter ID for quick lookup.
class _ChapterRange {
  final int startIndex;
  final int endIndex;
  final String chapterId;

  _ChapterRange({
    required this.startIndex,
    required this.endIndex,
    required this.chapterId,
  });

  bool contains(int itemIndex) =>
      itemIndex >= startIndex && itemIndex <= endIndex;
}

// ─────────────────────────────────────────────────────────────────────────────
// VerticalReaderView Widget
// ─────────────────────────────────────────────────────────────────────────────

/// Infinite-scroll ListView reader for vertical reading mode.
/// Adjacent chapters are preloaded and already in the item array before
/// the user reaches them. Chapter transitions feel seamless.
class VerticalReaderView extends BaseReaderView {
  const VerticalReaderView({
    super.key,
    required super.feedId,
    required super.bookId,
    required super.chapters,
    required super.initialChapterId,
    required super.initialParagraphIndex,
    required super.contentPadding,
    required super.onChapterChanged,
    required super.onParagraphChanged,
    super.bookTitle,
    super.bookAuthor,
    super.bookCoverUrl,
    super.bookDescription,
  });

  @override
  State<VerticalReaderView> createState() => _VerticalReaderViewState();
}

class _VerticalReaderViewState extends BaseReaderViewState<VerticalReaderView> {
  // ─ Controller
  late final ScrollController _scrollController;

  // ─ Cached view data
  List<_VerticalItem> _cachedItems = [];
  List<_ChapterRange> _chapterRanges = [];

  // ─ Abstract method implementations ───────────────────────────────────────

  @override
  void initController() {
    _scrollController = ScrollController()..addListener(_onScroll);
  }

  @override
  void disposeController() {
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
  }

  @override
  void onInitialLoadComplete() {
    _rebuildCache();
    setState(() {});
  }

  @override
  void restoreInitialPosition() {
    if (widget.initialParagraphIndex <= 0) return;

    final initialSlot = getSlot(widget.initialChapterId);
    final chapterLength = initialSlot?.content?.length ?? 0;
    if (chapterLength <= 1) return;

    final clampedParagraph = widget.initialParagraphIndex.clamp(
      0,
      chapterLength - 1,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;

      final maxExtent = _scrollController.position.maxScrollExtent;
      if (maxExtent <= 0) return;

      final ratio = clampedParagraph / (chapterLength - 1);
      final offset = (ratio * maxExtent).clamp(0.0, maxExtent);
      _scrollController.jumpTo(offset);
    });
  }

  @override
  bool isApproachingEnd() {
    if (!_scrollController.hasClients) return false;
    final maxExtent = _scrollController.position.maxScrollExtent;
    final currentExtent = _scrollController.offset;
    return maxExtent > 0 && (maxExtent - currentExtent) < 500;
  }

  @override
  bool isApproachingStart() {
    if (!_scrollController.hasClients) return false;
    return _scrollController.offset < 500;
  }

  @override
  void onSlotLoaded(ChapterSlot slot) {
    _rebuildCache();
  }

  @override
  void onSlotEvicted(ChapterSlot slot, bool fromTop) {
    _rebuildCache();
    if (fromTop && slot.content != null) {
      final estimatedHeight = slot.content!.length * 20.0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients && mounted) {
          final newOffset = (_scrollController.offset - estimatedHeight).clamp(
            0.0,
            double.infinity,
          );
          _scrollController.jumpTo(newOffset);
        }
      });
    }
  }

  // ─ Scroll Listener ───────────────────────────────────────────────────────

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    _detectVisibleChapter();
    preloadIfApproachingBoundary();
  }

  void _detectVisibleChapter() {
    if (_scrollController.position.pixels < 0) return;

    final maxExtent = _scrollController.position.maxScrollExtent;
    if (maxExtent <= 0) return;

    final ratio = (_scrollController.offset / maxExtent).clamp(0.0, 1.0);
    final estimatedIdx = (ratio * 100).round();

    for (final range in _chapterRanges) {
      if (range.contains(estimatedIdx)) {
        handleChapterBecameVisible(range.chapterId);
        break;
      }
    }

    updateParagraphIndex(estimatedIdx);
  }

  // ─ Cache Management ──────────────────────────────────────────────────────

  void _rebuildCache() {
    final items = <_VerticalItem>[];
    final ranges = <_ChapterRange>[];

    // Top boundary — always shown when any chapter is loaded.
    // Renders book info card at book start, loading spinner otherwise.
    if (hasTopBoundary) {
      items.add(const _VerticalItem(type: _VerticalItemType.topBoundary));
    }

    // Content from all loaded slots with separators
    for (int slotIdx = 0; slotIdx < loadedSlots.length; slotIdx++) {
      final slot = loadedSlots[slotIdx];
      if (slot.content == null) continue;

      final rangeStart = items.length;

      // Chapter separator (not before first chapter in view)
      if (slotIdx > 0) {
        items.add(
          _VerticalItem(
            type: _VerticalItemType.chapterSeparator,
            chapterTitle:
                slot.content!.isNotEmpty &&
                    slot.content!.first is ParagraphContentTitle
                ? (slot.content!.first as ParagraphContentTitle).text
                : AppLocalizations.of(
                    context,
                  ).readerChapterFallbackTitle(slot.chapterIndex + 1),
            chapterId: slot.chapterId,
          ),
        );
      }

      // Chapter content
      for (final paragraph in slot.content!) {
        items.add(
          _VerticalItem(
            type: _VerticalItemType.content,
            content: paragraph,
            chapterId: slot.chapterId,
          ),
        );
      }

      final rangeEnd = items.length - 1;
      ranges.add(
        _ChapterRange(
          startIndex: rangeStart,
          endIndex: rangeEnd,
          chapterId: slot.chapterId,
        ),
      );
    }

    // Bottom boundary — always shown when any chapter is loaded.
    // Renders end-of-book message at book end, loading spinner otherwise.
    if (hasBottomBoundary) {
      items.add(const _VerticalItem(type: _VerticalItemType.bottomBoundary));
    }

    _cachedItems = items;
    _chapterRanges = ranges;
  }

  // ─ Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (isInitialLoading && _cachedItems.isEmpty) {
      return Center(child: _buildLoadingBlock(context));
    }

    if (initialLoadError != null && _cachedItems.isEmpty) {
      return Center(
        child: _buildErrorBlock(
          context,
          onRetry: () {
            retryInitialLoad();
          },
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: widget.contentPadding,
      itemCount: _cachedItems.length,
      itemBuilder: (context, index) {
        final item = _cachedItems[index];

        switch (item.type) {
          case _VerticalItemType.topBoundary:
            return _buildTopBoundary(context);

          case _VerticalItemType.bottomBoundary:
            return _buildBottomBoundary(context);

          case _VerticalItemType.chapterSeparator:
            return _buildChapterSeparator(context, item.chapterTitle ?? '');

          case _VerticalItemType.content:
            if (item.content == null) {
              return const SizedBox.shrink();
            }
            return ParagraphView(item: item.content!);
        }
      },
    );
  }

  // ─ Boundary Widgets ─────────────────────────────────────────────────────

  Widget _buildTopBoundary(BuildContext context) {
    if (isAtBookStart) {
      return _buildBookInfoCard(context);
    }
    if (hasTopBoundaryError) {
      return _buildErrorBlock(
        context,
        onRetry: () {
          retryTopBoundary();
        },
      );
    }
    return _buildLoadingBlock(context);
  }

  Widget _buildBottomBoundary(BuildContext context) {
    if (isAtBookEnd) {
      return _buildEndOfBookBlock(context);
    }
    if (hasBottomBoundaryError) {
      return _buildErrorBlock(
        context,
        onRetry: () {
          retryBottomBoundary();
        },
      );
    }
    return _buildLoadingBlock(context);
  }

  Widget _buildBookInfoCard(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(32),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: widget.bookCoverUrl != null
                ? CoverImage(
                    url: widget.bookCoverUrl!,
                    width: 120,
                    height: 160,
                    placeholder: _buildCoverPlaceholder(context),
                  )
                : _buildCoverPlaceholder(context),
          ),
          if (widget.bookTitle != null) ...[
            const SizedBox(height: 16),
            Text(
              widget.bookTitle!,
              style: theme.textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
          ],
          if (widget.bookAuthor != null) ...[
            const SizedBox(height: 6),
            Text(
              widget.bookAuthor!,
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
          if (widget.bookDescription != null) ...[
            const SizedBox(height: 12),
            Text(
              widget.bookDescription!,
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCoverPlaceholder(BuildContext context) {
    return Container(
      width: 120,
      height: 160,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(Icons.menu_book_outlined, size: 48),
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

  Widget _buildLoadingBlock(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(32),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text(
            l10n.readerLoading,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBlock(
    BuildContext context, {
    required VoidCallback onRetry,
  }) {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(32),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.error_outline,
            size: 48,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(height: 12),
          Text(
            l10n.readerChapterLoadError,
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(onPressed: onRetry, child: Text(l10n.readerRetry)),
        ],
      ),
    );
  }

  Widget _buildChapterSeparator(BuildContext context, String title) {
    return Container(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Column(
        children: [
          Divider(),
          SizedBox(height: 8),
          Text(
            title,
            style: Theme.of(context).textTheme.labelMedium,
            textAlign: TextAlign.center,
          ),
          SizedBox(height: 8),
          Divider(),
        ],
      ),
    );
  }
}

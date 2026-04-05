import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../src/bindings/signals/signals.dart';
import '../../feeds/feed_service.dart';
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
class VerticalReaderView extends StatefulWidget {
  const VerticalReaderView({
    super.key,
    required this.feedId,
    required this.bookId,
    required this.chapters,
    required this.initialChapterId,
    required this.initialParagraphIndex,
    required this.contentPadding,
    required this.onChapterChanged,
    required this.onParagraphChanged,
  });

  final String feedId;
  final String bookId;
  final List<ChapterInfoModel> chapters;
  final String initialChapterId;
  final int initialParagraphIndex;
  final EdgeInsets contentPadding;
  final ValueChanged<String> onChapterChanged;
  final ValueChanged<int> onParagraphChanged;

  @override
  State<VerticalReaderView> createState() => _VerticalReaderViewState();
}

class _VerticalReaderViewState extends State<VerticalReaderView>
    with ChapterWindowManager<VerticalReaderView> {
  // ─ Controllers
  late final ScrollController _scrollController;

  // ─ Cached view data
  late List<_VerticalItem> _cachedItems = [];
  late List<_ChapterRange> _chapterRanges = [];

  // ─ Position tracking
  int _currentParagraphIndex = 0;
  String? _currentVisibleChapterId;

  @override
  void initState() {
    super.initState();
    initChapterWindow(
      chapters: widget.chapters,
      feedId: widget.feedId,
      bookId: widget.bookId,
    );

    _scrollController = ScrollController()..addListener(_onScroll);
    _currentParagraphIndex = widget.initialParagraphIndex;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _initialize();
    });
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    disposeChapterWindow();
    super.dispose();
  }

  // ─ Initialization ────────────────────────────────────────────────────────

  Future<void> _initialize() async {
    await loadInitial(widget.initialChapterId);
    if (mounted) {
      _rebuildCache();
      setState(() {});
      _restoreInitialPosition();
    }
  }

  void _restoreInitialPosition() {
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

  // ─ Scroll Listener ───────────────────────────────────────────────────────

  void _onScroll() {
    if (!_scrollController.hasClients) return;

    // Detect which chapter is visible based on scroll position
    _detectVisibleChapter();

    // Trigger preload if approaching boundary
    _preloadIfApproachingBoundary();
  }

  void _detectVisibleChapter() {
    if (_scrollController.position.pixels < 0) return;

    // For a rough estimate, assume average item height
    // In practice, this would require measuring actual item heights
    // For now, use scroll position to estimate visible paragraph
    final maxExtent = _scrollController.position.maxScrollExtent;
    if (maxExtent <= 0) return;

    final ratio = (_scrollController.offset / maxExtent).clamp(0.0, 1.0);
    _currentParagraphIndex = (ratio * 100).round(); // Rough estimate

    // Update current visible chapter based on cache ranges
    for (final range in _chapterRanges) {
      if (range.contains(_currentParagraphIndex)) {
        if (_currentVisibleChapterId != range.chapterId) {
          _currentVisibleChapterId = range.chapterId;
          setCurrentChapter(range.chapterId);
          widget.onChapterChanged(range.chapterId);
        }
        break;
      }
    }

    widget.onParagraphChanged(_currentParagraphIndex);
  }

  void _preloadIfApproachingBoundary() {
    if (!_scrollController.hasClients) return;

    final maxExtent = _scrollController.position.maxScrollExtent;
    final currentExtent = _scrollController.offset;

    // Approaching bottom? Trigger next chapter preload
    if (maxExtent > 0 && (maxExtent - currentExtent) < 500) {
      if (hasNewerUnloaded) {
        final nextIdx = loadedSlots.last.chapterIndex + 1;
        if (nextIdx < widget.chapters.length) {
          loadChapter(widget.chapters[nextIdx].id).catchError((_) {});
        }
      }
    }

    // Approaching top? Trigger prev chapter preload
    if (currentExtent < 500) {
      if (hasOlderUnloaded) {
        final prevIdx = loadedSlots.first.chapterIndex - 1;
        if (prevIdx >= 0) {
          loadChapter(widget.chapters[prevIdx].id).catchError((_) {});
        }
      }
    }
  }

  // ─ Cache Management ──────────────────────────────────────────────────────

  void _rebuildCache() {
    final items = <_VerticalItem>[];
    final ranges = <_ChapterRange>[];

    // Top boundary (only if first loaded chapter is not ch0)
    if (loadedSlots.isNotEmpty && loadedSlots.first.chapterIndex > 0) {
      items.add(
        _VerticalItem(
          type: _VerticalItemType.topBoundary,
          chapterTitle: olderChapterTitle,
        ),
      );
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

    // Bottom boundary (only if last loaded chapter is not last)
    if (loadedSlots.isNotEmpty &&
        loadedSlots.last.chapterIndex < widget.chapters.length - 1) {
      items.add(
        _VerticalItem(
          type: _VerticalItemType.bottomBoundary,
          chapterTitle: newerChapterTitle,
        ),
      );
    }

    _cachedItems = items;
    _chapterRanges = ranges;
  }

  // ─ ChapterWindowManager Callbacks ────────────────────────────────────────

  @override
  void onChapterLoaded(ChapterSlot slot) {
    if (mounted) {
      _rebuildCache();
      setState(() {});
    }
  }

  @override
  void onChaptersEvicted(ChapterSlot slot, bool fromTop) {
    if (mounted) {
      _rebuildCache();

      // If evicted from top, adjust scroll offset
      if (fromTop && slot.content != null) {
        // Calculate approximate height of evicted content
        // For now, use a rough estimate based on paragraph count
        final estimatedHeight =
            slot.content!.length * 20.0; // rough ~20 per paragraph
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients && mounted) {
            final newOffset = (_scrollController.offset - estimatedHeight)
                .clamp(0.0, double.infinity);
            _scrollController.jumpTo(newOffset);
          }
        });
      }

      setState(() {});
    }
  }

  // ─ Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: _scrollController,
      padding: widget.contentPadding,
      itemCount: _cachedItems.length,
      itemBuilder: (context, index) {
        final item = _cachedItems[index];

        switch (item.type) {
          case _VerticalItemType.topBoundary:
            return _buildBoundaryBlock(
              context,
              isTop: true,
              title:
                  item.chapterTitle ??
                  AppLocalizations.of(context).readerAtFirstChapter,
            );

          case _VerticalItemType.bottomBoundary:
            return _buildBoundaryBlock(
              context,
              isTop: false,
              title:
                  item.chapterTitle ??
                  AppLocalizations.of(context).readerAtLastChapter,
            );

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

  Widget _buildBoundaryBlock(
    BuildContext context, {
    required bool isTop,
    required String title,
  }) {
    return Container(
      padding: EdgeInsets.all(16),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(isTop ? Icons.arrow_upward : Icons.arrow_downward, size: 32),
          SizedBox(height: 8),
          Text(
            title,
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
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

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../src/bindings/signals/signals.dart';
import '../../feeds/feed_service.dart';
import 'chapter_window_manager.dart';
import 'page_breaker.dart';
import 'page_content_view.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Models
// ─────────────────────────────────────────────────────────────────────────────

/// Maps a range of page indices to a chapter ID for quick lookup.
class _PageRange {
  final int startIndex;
  final int endIndex;
  final String chapterId;

  _PageRange({
    required this.startIndex,
    required this.endIndex,
    required this.chapterId,
  });

  bool contains(int pageIndex) =>
      pageIndex >= startIndex && pageIndex <= endIndex;
}

// ─────────────────────────────────────────────────────────────────────────────
// HorizontalReaderView Widget
// ─────────────────────────────────────────────────────────────────────────────

/// Infinite-scroll PageView reader for horizontal paging mode.
/// Adjacent chapters' pages are preloaded and already in the flat page array
/// before the user reaches them. Chapter transitions are completely seamless.
class HorizontalReaderView extends StatefulWidget {
  const HorizontalReaderView({
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
  State<HorizontalReaderView> createState() => _HorizontalReaderViewState();
}

class _HorizontalReaderViewState extends State<HorizontalReaderView>
    with ChapterWindowManager<HorizontalReaderView> {
  // ─ Controllers
  late PageController _pageController;

  // ─ Cached view data
  late List<PageContent> _allPages = [];
  late List<_PageRange> _pageRanges = [];
  Size _lastPageSize = Size.zero;
  late PageBreaker _pageBreaker;

  // ─ Position tracking
  int _currentParagraphIndex = 0;
  String? _currentVisibleChapterId;
  int _currentPageIndex = 0;

  // ─ Boundary page counts
  int get _bookStartBoundaryPages {
    if (loadedSlots.isEmpty) return 0;
    return loadedSlots.first.chapterIndex == 0 ? 1 : 0;
  }

  int get _bookEndBoundaryPages {
    if (loadedSlots.isEmpty) return 0;
    return loadedSlots.last.chapterIndex == widget.chapters.length - 1 ? 1 : 0;
  }

  @override
  void initState() {
    super.initState();
    initChapterWindow(
      chapters: widget.chapters,
      feedId: widget.feedId,
      bookId: widget.bookId,
    );

    _pageController = PageController()
      ..addListener(() => _onPageChanged(_pageController.page?.toInt() ?? 0));
    _currentParagraphIndex = widget.initialParagraphIndex;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _initialize();
    });
  }

  @override
  void dispose() {
    _pageController
      ..removeListener(() => _onPageChanged(_pageController.page?.toInt() ?? 0))
      ..dispose();
    disposeChapterWindow();
    super.dispose();
  }

  // ─ Initialization ────────────────────────────────────────────────────────

  Future<void> _initialize() async {
    await loadInitial(widget.initialChapterId);
    if (mounted) {
      setState(() {
        _lastPageSize = Size(
          MediaQuery.of(context).size.width - widget.contentPadding.horizontal,
          MediaQuery.of(context).size.height - widget.contentPadding.vertical,
        );
        _initPageBreaker();
        _rebuildPages();
      });
      _restoreInitialPosition();
    }
  }

  void _restoreInitialPosition() {
    if (widget.initialParagraphIndex <= 0) return;
    if (_pageRanges.isEmpty || _allPages.isEmpty) return;

    int? contentPageIndex;
    for (final range in _pageRanges) {
      if (range.chapterId != widget.initialChapterId) continue;

      int candidate = range.startIndex;
      for (int i = range.startIndex; i <= range.endIndex; i++) {
        if (i < 0 || i >= _allPages.length) continue;
        if (_allPages[i].firstParagraphIndex <= widget.initialParagraphIndex) {
          candidate = i;
        } else {
          break;
        }
      }
      contentPageIndex = candidate;
      break;
    }

    if (contentPageIndex == null) return;

    final pageIndex = contentPageIndex + _bookStartBoundaryPages;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageController.hasClients) return;
      _pageController.jumpToPage(pageIndex);
    });
  }

  void _initPageBreaker() {
    final theme = Theme.of(context);
    final bodyLarge =
        theme.textTheme.bodyLarge?.copyWith(height: 1.8) ??
        const TextStyle(fontSize: 16, height: 1.8);
    final headlineSmall =
        theme.textTheme.headlineSmall ?? const TextStyle(fontSize: 24);

    _pageBreaker = PageBreaker(
      pageSize: _lastPageSize,
      textStyle: bodyLarge,
      titleStyle: headlineSmall,
      paragraphSpacing: LanghuanTheme.spaceMd,
      imageHeight: _lastPageSize.width * 9 / 16,
      textDirection: Directionality.of(context),
    );
  }

  // ─ Page Changed Listener ─────────────────────────────────────────────────

  void _onPageChanged(int pageIndex) {
    if (!_pageController.hasClients) return;

    _currentPageIndex = pageIndex;

    // Adjust for boundary pages
    int contentPageIndex = pageIndex - _bookStartBoundaryPages;

    // Detect which chapter this page belongs to
    for (final range in _pageRanges) {
      if (range.contains(contentPageIndex)) {
        if (_currentVisibleChapterId != range.chapterId) {
          _currentVisibleChapterId = range.chapterId;
          setCurrentChapter(range.chapterId);
          widget.onChapterChanged(range.chapterId);
        }

        // Update paragraph index
        final contentPageIdx = contentPageIndex - range.startIndex;
        if (contentPageIdx >= 0 && contentPageIdx < _allPages.length) {
          _currentParagraphIndex =
              _allPages[contentPageIdx].firstParagraphIndex;
          widget.onParagraphChanged(_currentParagraphIndex);
        }
        break;
      }
    }

    // Trigger preload if approaching boundary
    _preloadIfApproachingBoundary();
  }

  void _preloadIfApproachingBoundary() {
    final totalPages =
        _allPages.length + _bookStartBoundaryPages + _bookEndBoundaryPages;

    // Approaching end boundary?
    if (_currentPageIndex > totalPages - 3) {
      if (hasNewerUnloaded) {
        final nextIdx = loadedSlots.last.chapterIndex + 1;
        if (nextIdx < widget.chapters.length) {
          loadChapter(widget.chapters[nextIdx].id).catchError((_) {});
        }
      }
    }

    // Approaching start boundary?
    if (_currentPageIndex < 3) {
      if (hasOlderUnloaded) {
        final prevIdx = loadedSlots.first.chapterIndex - 1;
        if (prevIdx >= 0) {
          loadChapter(widget.chapters[prevIdx].id).catchError((_) {});
        }
      }
    }
  }

  // ─ Page Array Management ─────────────────────────────────────────────────

  void _rebuildPages() {
    final pages = <PageContent>[];
    final ranges = <_PageRange>[];

    // Book start boundary page (if first chapter)
    if (_bookStartBoundaryPages > 0) {
      pages.add(
        PageContent(
          items: [
            PageItem(
              source: ParagraphContentText(
                content: AppLocalizations.of(context).readerAtFirstChapter,
              ),
              paragraphIndex: -1,
            ),
          ],
        ),
      );
    }

    // Content pages from all loaded slots
    for (int slotIdx = 0; slotIdx < loadedSlots.length; slotIdx++) {
      final slot = loadedSlots[slotIdx];
      if (slot.pages.isEmpty) continue;

      final rangeStart = pages.length;

      // Add all pages from this chapter
      pages.addAll(slot.pages);

      final rangeEnd = pages.length - 1;
      ranges.add(
        _PageRange(
          startIndex: rangeStart,
          endIndex: rangeEnd,
          chapterId: slot.chapterId,
        ),
      );
    }

    // Book end boundary page (if last chapter)
    if (_bookEndBoundaryPages > 0) {
      pages.add(
        PageContent(
          items: [
            PageItem(
              source: ParagraphContentText(
                content: AppLocalizations.of(context).readerAtLastChapter,
              ),
              paragraphIndex: -1,
            ),
          ],
        ),
      );
    }

    _allPages = pages;
    _pageRanges = ranges;
  }

  // ─ ChapterWindowManager Callbacks ────────────────────────────────────────

  @override
  void onChapterLoaded(ChapterSlot slot) {
    if (mounted) {
      setState(() {
        // Compute pages for this chapter
        if (_lastPageSize.isEmpty) {
          _initPageBreaker();
        }
        slot.pages = _pageBreaker.computePages(slot.content ?? []);
        _rebuildPages();
      });
    }
  }

  @override
  void onChaptersEvicted(ChapterSlot slot, bool fromTop) {
    if (mounted) {
      _rebuildPages();

      // If evicted from top, adjust page offset
      if (fromTop && slot.pages.isNotEmpty) {
        final pagesRemoved = slot.pages.length;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_pageController.hasClients && mounted) {
            final newPage = (_pageController.page ?? 0) - pagesRemoved;
            _pageController.jumpToPage(
              newPage.toInt().clamp(0, _allPages.length - 1),
            );
          }
        });
      }

      setState(() {});
    }
  }

  // ─ Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Update page size if changed
        final newSize = Size(
          constraints.maxWidth - widget.contentPadding.horizontal,
          constraints.maxHeight - widget.contentPadding.vertical,
        );
        if (_lastPageSize != newSize && _lastPageSize != Size.zero) {
          _lastPageSize = newSize;
          _initPageBreaker();
        } else if (_lastPageSize == Size.zero) {
          _lastPageSize = newSize;
          _initPageBreaker();
        }

        return PageView.builder(
          controller: _pageController,
          itemCount:
              _allPages.length +
              _bookStartBoundaryPages +
              _bookEndBoundaryPages,
          itemBuilder: (context, pageIndex) {
            // Boundary pages
            if (pageIndex < _bookStartBoundaryPages) {
              return _buildStartBoundaryPage(context);
            }
            if (pageIndex >= _allPages.length + _bookStartBoundaryPages) {
              return _buildEndBoundaryPage(context);
            }

            // Content page
            final contentPageIndex = pageIndex - _bookStartBoundaryPages;
            if (contentPageIndex < 0 || contentPageIndex >= _allPages.length) {
              return const SizedBox.shrink();
            }

            return Padding(
              padding: widget.contentPadding,
              child: PageContentView(page: _allPages[contentPageIndex]),
            );
          },
        );
      },
    );
  }

  Widget _buildStartBoundaryPage(BuildContext context) {
    return Container(
      padding: widget.contentPadding,
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.arrow_downward, size: 48),
          SizedBox(height: 16),
          Text(
            AppLocalizations.of(context).readerAtFirstChapter,
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildEndBoundaryPage(BuildContext context) {
    return Container(
      padding: widget.contentPadding,
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.arrow_upward, size: 48),
          SizedBox(height: 16),
          Text(
            AppLocalizations.of(context).readerAtLastChapter,
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

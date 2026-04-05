import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import 'base_reader_view.dart';
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
class HorizontalReaderView extends BaseReaderView {
  const HorizontalReaderView({
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
  State<HorizontalReaderView> createState() => _HorizontalReaderViewState();
}

class _HorizontalReaderViewState
    extends BaseReaderViewState<HorizontalReaderView> {
  // ─ Controllers
  late PageController _pageController;

  // ─ Cached view data
  List<PageContent> _allPages = [];
  List<_PageRange> _pageRanges = [];
  Size _lastPageSize = Size.zero;
  late PageBreaker _pageBreaker;

  // ─ Position tracking
  int _currentPageIndex = 0;

  // ─ Boundary page counts
  int get _bookStartBoundaryPages => hasTopBoundary ? 1 : 0;
  int get _bookEndBoundaryPages => hasBottomBoundary ? 1 : 0;

  // ─ Abstract method implementations ───────────────────────────────────────

  @override
  void initController() {
    _pageController = PageController()
      ..addListener(() => _onPageChanged(_pageController.page?.toInt() ?? 0));
  }

  @override
  void disposeController() {
    _pageController
      ..removeListener(() => _onPageChanged(_pageController.page?.toInt() ?? 0))
      ..dispose();
  }

  @override
  void onInitialLoadComplete() {
    setState(() {
      _lastPageSize = Size(
        MediaQuery.of(context).size.width - widget.contentPadding.horizontal,
        MediaQuery.of(context).size.height - widget.contentPadding.vertical,
      );
      _initPageBreaker();
      // Recompute pages for all slots now that we have the correct page size.
      for (final slot in loadedSlots) {
        if (slot.content != null) {
          slot.pages = _pageBreaker.computePages(slot.content!);
        }
      }
      _rebuildPages();
    });
  }

  @override
  bool isApproachingEnd() {
    final totalPages =
        _allPages.length + _bookStartBoundaryPages + _bookEndBoundaryPages;
    return _currentPageIndex > totalPages - 3;
  }

  @override
  bool isApproachingStart() => _currentPageIndex < 3;

  @override
  void onSlotLoaded(ChapterSlot slot) {
    if (_lastPageSize.isEmpty) {
      _initPageBreaker();
    }
    slot.pages = _pageBreaker.computePages(slot.content ?? []);
    _rebuildPages();
  }

  @override
  void onSlotEvicted(ChapterSlot slot, bool fromTop) {
    _rebuildPages();
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
  }

  @override
  void restoreInitialPosition() {
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
    final contentPageIndex = pageIndex - _bookStartBoundaryPages;

    // Detect which chapter this page belongs to
    for (final range in _pageRanges) {
      if (range.contains(contentPageIndex)) {
        handleChapterBecameVisible(range.chapterId);

        // Update paragraph index
        final contentPageIdx = contentPageIndex - range.startIndex;
        if (contentPageIdx >= 0 && contentPageIdx < _allPages.length) {
          updateParagraphIndex(_allPages[contentPageIdx].firstParagraphIndex);
        }
        break;
      }
    }

    preloadIfApproachingBoundary();
  }

  // ─ Page Array Management ─────────────────────────────────────────────────

  void _rebuildPages() {
    final pages = <PageContent>[];
    final ranges = <_PageRange>[];

    // Boundary pages are rendered as custom widgets in itemBuilder.
    // Only content pages are tracked in _allPages / _pageRanges.
    for (int slotIdx = 0; slotIdx < loadedSlots.length; slotIdx++) {
      final slot = loadedSlots[slotIdx];
      if (slot.pages.isEmpty) continue;

      final rangeStart = pages.length;
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

    _allPages = pages;
    _pageRanges = ranges;
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

  Widget _buildStartBoundaryPage(BuildContext context) =>
      isAtBookStart ? _buildBookInfoPage(context) : _buildLoadingPage(context);

  Widget _buildEndBoundaryPage(BuildContext context) =>
      isAtBookEnd ? _buildEndOfBookPage(context) : _buildLoadingPage(context);

  Widget _buildBookInfoPage(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: widget.contentPadding,
      child: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: widget.bookCoverUrl != null
                    ? Stack(
                        children: [
                          _buildCoverPlaceholder(context),
                          Image.network(
                            widget.bookCoverUrl!,
                            width: 160,
                            height: 210,
                            fit: BoxFit.cover,
                            frameBuilder:
                                (
                                  context,
                                  child,
                                  frame,
                                  wasSynchronouslyLoaded,
                                ) {
                                  if (wasSynchronouslyLoaded) {
                                    return child;
                                  }
                                  return AnimatedOpacity(
                                    opacity: frame == null ? 0.0 : 1.0,
                                    duration: const Duration(milliseconds: 220),
                                    curve: Curves.easeOut,
                                    child: child,
                                  );
                                },
                            errorBuilder: (_, __, ___) =>
                                _buildCoverPlaceholder(context),
                          ),
                        ],
                      )
                    : _buildCoverPlaceholder(context),
              ),
              if (widget.bookTitle != null) ...[
                const SizedBox(height: 20),
                Text(
                  widget.bookTitle!,
                  style: theme.textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
              ],
              if (widget.bookAuthor != null) ...[
                const SizedBox(height: 8),
                Text(
                  widget.bookAuthor!,
                  style: theme.textTheme.bodyLarge,
                  textAlign: TextAlign.center,
                ),
              ],
              if (widget.bookDescription != null) ...[
                const SizedBox(height: 16),
                Text(
                  widget.bookDescription!,
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCoverPlaceholder(BuildContext context) {
    return Container(
      width: 160,
      height: 210,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(Icons.menu_book_outlined, size: 64),
    );
  }

  Widget _buildEndOfBookPage(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: widget.contentPadding,
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.check_circle_outline,
            size: 64,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            l10n.readerEndOfBook,
            style: Theme.of(context).textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingPage(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: widget.contentPadding,
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            l10n.readerLoading,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
}

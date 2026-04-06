import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/error_state.dart';
import '../feeds/feed_service.dart';
import 'book_providers.dart';
import 'reading_progress_provider.dart';
import 'widgets/chapter_content_manager.dart';
import 'widgets/reader_bottom_bar.dart';
import 'widgets/reader_types.dart';

class ReaderPage extends ConsumerStatefulWidget {
  const ReaderPage({
    super.key,
    required this.feedId,
    required this.bookId,
    required this.chapterId,
    this.paragraphIndex = 0,
  });

  final String feedId;
  final String bookId;
  final String chapterId;
  final int paragraphIndex;

  @override
  ConsumerState<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends ConsumerState<ReaderPage> {
  static const Duration _controlsAutoHideDelay = Duration(seconds: 3);

  // ─ Loading and error state
  bool _isLoadingInitial = false;
  Object? _loadError;

  // ─ Chapter and progress state
  String? _currentChapterId;
  List<ChapterInfoModel> _chapters = const [];
  int _currentParagraphIndex = 0;
  double _currentParagraphOffset = 0;

  // ─ UI state
  bool _showControls = false;
  ReaderMode _readerMode = ReaderMode.verticalScroll;

  // ─ Controllers and notifiers
  late final ReadingProgressNotifier _readingProgressNotifier;
  Timer? _controlsTimer;

  @override
  void initState() {
    super.initState();
    _readingProgressNotifier = ref.read(readingProgressProvider.notifier);
    _currentChapterId = widget.chapterId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ensureLoaded();
    });
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    super.dispose();
  }

  void _toggleControls() {
    setState(() {
      _showControls = !_showControls;
    });

    _controlsTimer?.cancel();
    if (_showControls) {
      _controlsTimer = Timer(_controlsAutoHideDelay, () {
        if (!mounted) return;
        setState(() {
          _showControls = false;
        });
      });
    }
  }

  void _onChapterChanged(String chapterId) {
    if (_currentChapterId != chapterId) {
      setState(() {
        _currentChapterId = chapterId;
      });
    }
    _saveReadingProgressNow();
  }

  void _jumpToChapter(String chapterId) {
    if (_currentChapterId == chapterId && _currentParagraphIndex == 0) {
      return;
    }
    setState(() {
      _currentChapterId = chapterId;
      _currentParagraphIndex = 0;
      _currentParagraphOffset = 0;
    });
    _saveReadingProgressNow();
  }

  void _onParagraphChanged(int paragraphIndex) {
    _currentParagraphIndex = paragraphIndex;
    _saveReadingProgressNow();
  }

  void _onParagraphOffsetChanged(double offset) {
    _currentParagraphOffset = offset;
    _saveReadingProgressNow();
  }

  void _saveReadingProgressNow() {
    if (!mounted) return;
    unawaited(_saveReadingProgress());
  }

  Future<void> _saveReadingProgress() async {
    final chapterId = _currentChapterId;
    if (chapterId == null || chapterId.isEmpty) return;

    await _readingProgressNotifier.save(
      feedId: widget.feedId,
      bookId: widget.bookId,
      chapterId: chapterId,
      paragraphIndex: _currentParagraphIndex,
    );
  }

  Future<void> _ensureLoaded() async {
    if (widget.feedId.isEmpty || widget.bookId.isEmpty) return;

    setState(() {
      _isLoadingInitial = true;
      _loadError = null;
    });

    try {
      final chapters = await _loadChaptersSnapshot();
      final progress = await FeedService.instance.getReadingProgress(
        feedId: widget.feedId,
        bookId: widget.bookId,
      );
      // Load book info in background — boundary widgets will update reactively.
      unawaited(
        ref
            .read(bookInfoProvider.notifier)
            .load(feedId: widget.feedId, bookId: widget.bookId),
      );
      final resolvedChapterId = _resolveInitialChapterId(chapters, progress);
      // Use router paragraph if the router specified a chapter and it matches,
      // otherwise fall back to saved reading progress.
      int initialParagraphIndex;
      if (widget.chapterId.isNotEmpty &&
          widget.chapterId == resolvedChapterId &&
          widget.paragraphIndex > 0) {
        initialParagraphIndex = widget.paragraphIndex;
      } else if (progress != null && progress.chapterId == resolvedChapterId) {
        initialParagraphIndex = progress.paragraphIndex;
      } else {
        initialParagraphIndex = 0;
      }

      if (!mounted) return;

      setState(() {
        _chapters = chapters;
        _currentChapterId = resolvedChapterId;
        _currentParagraphIndex = initialParagraphIndex;
        _currentParagraphOffset = 0;
        _isLoadingInitial = false;
        _loadError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoadingInitial = false;
        _loadError = error;
      });
    }
  }

  Future<List<ChapterInfoModel>> _loadChaptersSnapshot() async {
    final cached = ref.read(chaptersProvider);
    if (cached.feedId == widget.feedId &&
        cached.bookId == widget.bookId &&
        cached.items.isNotEmpty) {
      return cached.items;
    }
    return FeedService.instance
        .chapters(feedId: widget.feedId, bookId: widget.bookId)
        .stream
        .toList();
  }

  String _resolveInitialChapterId(
    List<ChapterInfoModel> chapters,
    ReadingProgressModel? progress,
  ) {
    if (widget.chapterId.isNotEmpty &&
        chapters.any((chapter) => chapter.id == widget.chapterId)) {
      return widget.chapterId;
    }

    if (progress != null &&
        progress.chapterId.isNotEmpty &&
        chapters.any((chapter) => chapter.id == progress.chapterId)) {
      return progress.chapterId;
    }

    if (chapters.isNotEmpty) {
      return chapters.first.id;
    }

    return '';
  }

  int _currentChapterIndex(String? chapterId) {
    if (chapterId == null) return -1;
    return _chapters.indexWhere((c) => c.id == chapterId);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    if (widget.feedId.isEmpty || widget.bookId.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.readerTitle)),
        body: EmptyState(
          icon: Icons.info_outline,
          title: l10n.readerMissingParams,
        ),
      );
    }

    if (_isLoadingInitial) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.readerTitle)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_loadError != null && _chapters.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.readerTitle)),
        body: ErrorState(
          title: l10n.readerLoadError,
          message: _loadError.toString(),
          onRetry: _ensureLoaded,
          retryLabel: l10n.bookDetailRetry,
        ),
      );
    }

    if (_chapters.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.readerTitle)),
        body: EmptyState(
          icon: Icons.menu_book_outlined,
          title: l10n.readerEmpty,
        ),
      );
    }

    final currentIdx = _currentChapterIndex(_currentChapterId);
    final chapterTitle = currentIdx >= 0
        ? _chapters[currentIdx].title
        : l10n.readerTitle;

    final mediaQuery = MediaQuery.of(context);
    final topPadding = mediaQuery.padding.top;
    final bottomPadding = mediaQuery.padding.bottom;
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final overlayStyle = brightness == Brightness.dark
        ? SystemUiOverlayStyle.light
        : SystemUiOverlayStyle.dark;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: Scaffold(
        extendBody: true,
        extendBodyBehindAppBar: true,
        body: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _toggleControls,
          child: Stack(
            children: [
              // Content area
              Positioned.fill(
                child: ChapterContentManager(
                  feedId: widget.feedId,
                  bookId: widget.bookId,
                  chapters: _chapters,
                  initialChapterId: _currentChapterId ?? _chapters.first.id,
                  initialParagraphIndex: _currentParagraphIndex,
                  initialParagraphOffset: _currentParagraphOffset,
                  readerMode: _readerMode,
                  contentPadding: EdgeInsets.fromLTRB(
                    LanghuanTheme.spaceLg,
                    topPadding + LanghuanTheme.spaceLg,
                    LanghuanTheme.spaceLg,
                    bottomPadding + LanghuanTheme.space2xl,
                  ),
                  onChapterChanged: _onChapterChanged,
                  onParagraphChanged: _onParagraphChanged,
                  onParagraphOffsetChanged: _onParagraphOffsetChanged,
                ),
              ),

              // ─ Top bar overlay
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  ignoring: !_showControls,
                  child: AnimatedSlide(
                    duration: const Duration(milliseconds: 180),
                    offset: _showControls ? Offset.zero : const Offset(0, -1),
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 180),
                      opacity: _showControls ? 1 : 0,
                      child: Container(
                        color: theme.colorScheme.surfaceContainer,
                        padding: EdgeInsets.only(top: topPadding),
                        child: Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.arrow_back),
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                            Expanded(
                              child: Text(
                                chapterTitle,
                                style: theme.textTheme.titleMedium,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            PopupMenuButton<ReaderMode>(
                              initialValue: _readerMode,
                              onSelected: (mode) => setState(() {
                                _readerMode = mode;
                              }),
                              itemBuilder: (context) => [
                                PopupMenuItem<ReaderMode>(
                                  value: ReaderMode.verticalScroll,
                                  child: Text(l10n.readerModeVertical),
                                ),
                                PopupMenuItem<ReaderMode>(
                                  value: ReaderMode.horizontalPaging,
                                  child: Text(l10n.readerModeHorizontal),
                                ),
                              ],
                              icon: const Icon(Icons.swap_horiz),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // ─ Bottom bar overlay
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  ignoring: !_showControls,
                  child: AnimatedSlide(
                    duration: const Duration(milliseconds: 180),
                    offset: _showControls ? Offset.zero : const Offset(0, 1),
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 180),
                      opacity: _showControls ? 1 : 0,
                      child: ReaderBottomBar(
                        chapters: _chapters,
                        currentIndex: currentIdx,
                        isSwitchingChapter: false,
                        onPrevious: () {
                          if (currentIdx > 0) {
                            _jumpToChapter(_chapters[currentIdx - 1].id);
                          }
                        },
                        onNext: () {
                          if (currentIdx < _chapters.length - 1) {
                            _jumpToChapter(_chapters[currentIdx + 1].id);
                          }
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

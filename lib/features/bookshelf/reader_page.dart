import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/error_state.dart';
import '../../src/bindings/signals/signals.dart';
import '../feeds/feed_service.dart';
import 'book_providers.dart';
import 'reading_progress_provider.dart';
import 'widgets/paragraph_view.dart';
import 'widgets/reader_bottom_bar.dart';

enum _ReaderMode { verticalScroll, horizontalPaging }

enum _LoadingState { initialLoading, contentLoading, ready }

class ReaderPage extends ConsumerStatefulWidget {
  const ReaderPage({
    super.key,
    required this.feedId,
    required this.bookId,
    required this.chapterId,
  });

  final String feedId;
  final String bookId;
  final String chapterId;

  @override
  ConsumerState<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends ConsumerState<ReaderPage> {
  static const double _swipeVelocityThreshold = 220;
  static const Duration _progressSaveDebounce = Duration(seconds: 1);
  static const Duration _controlsAutoHideDelay = Duration(seconds: 3);
  static const int _restorePositionMaxAttempts = 8;

  // ─ Loading and error state
  _LoadingState _loadingState = _LoadingState.initialLoading;
  Object? _loadError;

  // ─ Chapter and content state
  String? _currentChapterId;
  List<ChapterInfoModel> _chapters = const [];
  List<ParagraphContent> _latestContentItems = const [];
  bool _restoredPosition = false;

  // ─ Position tracking (cached for safe dispose access)
  int _currentParagraphIndex = 0;

  // ─ UI state
  bool _showBottomBar = false;
  bool _isSwitchingChapter = false;
  _ReaderMode _readerMode = _ReaderMode.verticalScroll;

  // ─ Controllers and notifiers
  late final ScrollController _scrollController;
  late final PageController _pageController;
  late final ReadingProgressNotifier _readingProgressNotifier;
  Timer? _saveTimer;
  Timer? _controlsTimer;

  // ─ Computed state helpers
  bool get _isLoading =>
      _loadingState == _LoadingState.initialLoading ||
      (_loadingState == _LoadingState.contentLoading &&
          _latestContentItems.isEmpty);
  bool get _isContentEmpty => _latestContentItems.isEmpty;
  bool get _hasError => _loadError != null;

  @override
  void initState() {
    super.initState();
    _readingProgressNotifier = ref.read(readingProgressProvider.notifier);
    _scrollController = ScrollController()..addListener(_onScroll);
    _pageController = PageController();
    _currentChapterId = widget.chapterId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ensureLoaded();
    });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _controlsTimer?.cancel();
    unawaited(_saveReadingProgress(updateProviderState: false));
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_readerMode != _ReaderMode.verticalScroll) return;
    if (!_scrollController.hasClients) return;
    _currentParagraphIndex = _estimateParagraphIndex(
      _latestContentItems.length,
    );
    _scheduleSaveProgress();
  }

  void _onPageChanged(int index) {
    if (_readerMode != _ReaderMode.horizontalPaging) return;
    _currentParagraphIndex = index;
    _scheduleSaveProgress();
  }

  void _scheduleSaveProgress() {
    _saveTimer?.cancel();
    _saveTimer = Timer(_progressSaveDebounce, () {
      if (!mounted) return;
      unawaited(_saveReadingProgress(updateProviderState: true));
    });
  }

  void _toggleBottomBar() {
    setState(() {
      _showBottomBar = !_showBottomBar;
    });

    _controlsTimer?.cancel();
    if (_showBottomBar) {
      _controlsTimer = Timer(_controlsAutoHideDelay, () {
        if (!mounted) return;
        setState(() {
          _showBottomBar = false;
        });
      });
    }
  }

  int _estimateParagraphIndex(int totalItems) {
    if (totalItems <= 1) {
      return 0;
    }

    if (_readerMode == _ReaderMode.horizontalPaging) {
      return _currentParagraphIndex.clamp(0, totalItems - 1);
    }

    if (!_scrollController.hasClients) {
      return 0;
    }

    final maxExtent = _scrollController.position.maxScrollExtent;
    if (maxExtent <= 0) {
      return 0;
    }

    final ratio = (_scrollController.offset / maxExtent).clamp(0.0, 1.0);
    return (ratio * (totalItems - 1)).round();
  }

  Future<void> _saveReadingProgress({required bool updateProviderState}) async {
    final chapterId = _currentChapterId;
    if (chapterId == null || chapterId.isEmpty) {
      return;
    }

    // Use cached value so this is safe even when called from dispose(),
    // when the ScrollController may already be detached.
    final paragraphIndex = _currentParagraphIndex;

    if (updateProviderState) {
      await _readingProgressNotifier.save(
        feedId: widget.feedId,
        bookId: widget.bookId,
        chapterId: chapterId,
        paragraphIndex: paragraphIndex,
      );
      return;
    }

    await FeedService.instance.setReadingProgress(
      feedId: widget.feedId,
      bookId: widget.bookId,
      chapterId: chapterId,
      paragraphIndex: paragraphIndex,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> _ensureLoaded() async {
    if (widget.feedId.isEmpty || widget.bookId.isEmpty) {
      return;
    }

    setState(() {
      _loadingState = _LoadingState.initialLoading;
      _loadError = null;
    });

    try {
      final chapters = await _loadChaptersSnapshot();
      final progress = await FeedService.instance.getReadingProgress(
        feedId: widget.feedId,
        bookId: widget.bookId,
      );
      final resolvedChapterId = _resolveInitialChapterId(chapters, progress);
      final contentItems = resolvedChapterId.isEmpty
          ? const <ParagraphContent>[]
          : await _loadChapterContentSnapshot(chapterId: resolvedChapterId);

      if (!mounted) {
        return;
      }

      final initialProgress =
          progress != null && progress.chapterId == resolvedChapterId
          ? progress
          : null;

      setState(() {
        _chapters = chapters;
        _currentChapterId = resolvedChapterId;
        _latestContentItems = contentItems;
        _currentParagraphIndex =
            initialProgress?.paragraphIndex.clamp(
              0,
              contentItems.isEmpty ? 0 : contentItems.length - 1,
            ) ??
            0;
        _restoredPosition = false;
        _loadingState = _LoadingState.ready;
        _loadError = null;
      });

      _applyInitialPosition(
        progress: initialProgress,
        totalItems: contentItems.length,
        chapterId: resolvedChapterId,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loadingState = _LoadingState.ready;
        _loadError = error;
      });
    }
  }

  Future<List<ChapterInfoModel>> _loadChaptersSnapshot() async {
    final cached = ref.read(chaptersProvider);
    if (cached.bookId == widget.bookId && cached.items.isNotEmpty) {
      return cached.items;
    }
    return FeedService.instance
        .chapters(feedId: widget.feedId, bookId: widget.bookId)
        .stream
        .toList();
  }

  Future<List<ParagraphContent>> _loadChapterContentSnapshot({
    required String chapterId,
  }) async {
    final cached = ref.read(chapterContentProvider);
    if (cached.feedId == widget.feedId &&
        cached.bookId == widget.bookId &&
        cached.chapterId == chapterId &&
        cached.items.isNotEmpty &&
        !cached.isLoading) {
      return cached.items;
    }
    return FeedService.instance
        .chapterContent(
          feedId: widget.feedId,
          bookId: widget.bookId,
          chapterId: chapterId,
        )
        .stream
        .toList();
  }

  String _resolveInitialChapterId(
    List<ChapterInfoModel> chapters,
    ReadingProgressModel? progress,
  ) {
    if (progress != null &&
        progress.chapterId.isNotEmpty &&
        chapters.any((chapter) => chapter.id == progress.chapterId)) {
      return progress.chapterId;
    }

    if (widget.chapterId.isNotEmpty &&
        chapters.any((chapter) => chapter.id == widget.chapterId)) {
      return widget.chapterId;
    }

    if (chapters.isNotEmpty) {
      return chapters.first.id;
    }

    return '';
  }

  void _applyInitialPosition({
    required ReadingProgressModel? progress,
    required int totalItems,
    required String chapterId,
  }) {
    if (chapterId.isEmpty) {
      return;
    }

    if (progress == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_readerMode == _ReaderMode.horizontalPaging) {
          if (_pageController.hasClients) {
            _pageController.jumpToPage(0);
          }
        } else if (_scrollController.hasClients) {
          _scrollController.jumpTo(0);
        }
        _restoredPosition = true;
      });
      return;
    }

    _restoreReadingPosition(
      progress,
      totalItems,
      chapterId,
      _restorePositionMaxAttempts,
    );
  }

  void _restoreReadingPosition(
    ReadingProgressModel? progress,
    int totalItems,
    String chapterId,
    int attemptsRemaining,
  ) {
    if (_restoredPosition ||
        progress == null ||
        progress.chapterId != chapterId ||
        attemptsRemaining <= 0) {
      return;
    }

    final targetParagraph = progress.paragraphIndex.clamp(
      0,
      totalItems <= 0 ? 0 : totalItems - 1,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_readerMode == _ReaderMode.horizontalPaging) {
        _currentParagraphIndex = targetParagraph;
        if (_pageController.hasClients) {
          _pageController.jumpToPage(targetParagraph);
          _restoredPosition = true;
          return;
        }
      } else if (_scrollController.hasClients) {
        final maxExtent = _scrollController.position.maxScrollExtent;
        if (maxExtent > 0) {
          final paragraphOffset = totalItems <= 1
              ? 0.0
              : maxExtent * (targetParagraph / (totalItems - 1));
          final target = paragraphOffset.clamp(0.0, maxExtent);
          _scrollController.jumpTo(target);
          _currentParagraphIndex = targetParagraph;
          _restoredPosition = true;
          return;
        }
      }

      _restoreReadingPosition(
        progress,
        totalItems,
        chapterId,
        attemptsRemaining - 1,
      );
    });
  }

  Future<void> _switchReaderMode(_ReaderMode nextMode, int totalItems) async {
    if (nextMode == _readerMode) return;

    setState(() {
      _readerMode = nextMode;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      if (_readerMode == _ReaderMode.horizontalPaging) {
        final target = _currentParagraphIndex.clamp(
          0,
          totalItems <= 0 ? 0 : totalItems - 1,
        );
        if (_pageController.hasClients) {
          _pageController.jumpToPage(target);
        }
      } else {
        if (!_scrollController.hasClients || totalItems <= 1) return;
        final ratio = _currentParagraphIndex / (totalItems - 1);
        final target = _scrollController.position.maxScrollExtent * ratio;
        _scrollController.jumpTo(
          target.clamp(0.0, _scrollController.position.maxScrollExtent),
        );
      }
    });
  }

  int _currentChapterIndex(List<ChapterInfoModel> chapters) {
    final chapterId = _currentChapterId;
    if (chapterId == null) return -1;
    return chapters.indexWhere((c) => c.id == chapterId);
  }

  Future<void> _jumpToChapter(
    BuildContext context,
    List<ChapterInfoModel> chapters,
    int targetIndex,
  ) async {
    if (_isSwitchingChapter) return;

    final l10n = AppLocalizations.of(context);
    if (targetIndex < 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.readerAtFirstChapter)));
      return;
    }
    if (targetIndex >= chapters.length) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.readerAtLastChapter)));
      return;
    }

    if (ref.read(chapterContentProvider).isLoading) return;

    final target = chapters[targetIndex];
    await _saveReadingProgress(updateProviderState: true);

    _isSwitchingChapter = true;
    setState(() {
      _currentChapterId = target.id;
      _restoredPosition = false;
      _currentParagraphIndex = 0;
      _loadingState = _LoadingState.contentLoading;
      _loadError = null;
      _latestContentItems = const [];
    });

    try {
      final items = await _loadChapterContentSnapshot(chapterId: target.id);
      if (!mounted) return;

      setState(() {
        _latestContentItems = items;
        _loadingState = _LoadingState.ready;
      });

      _applyInitialPosition(
        progress: null,
        totalItems: items.length,
        chapterId: target.id,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingState = _LoadingState.ready;
        _loadError = error;
      });
    } finally {
      if (mounted) setState(() => _isSwitchingChapter = false);
    }
  }

  Future<void> _onHorizontalDragEnd(
    BuildContext context,
    DragEndDetails details,
    List<ChapterInfoModel> chapters,
  ) async {
    if (_readerMode != _ReaderMode.verticalScroll) return;

    final v = details.primaryVelocity ?? 0;
    if (v.abs() < _swipeVelocityThreshold) return;

    final idx = _currentChapterIndex(chapters);
    if (idx < 0) return;

    await _jumpToChapter(context, chapters, v < 0 ? idx + 1 : idx - 1);
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

    final chapters = _chapters;
    final currentIdx = _currentChapterIndex(chapters);
    final chapterTitle = currentIdx >= 0
        ? chapters[currentIdx].title
        : l10n.readerTitle;

    return Scaffold(
      appBar: AppBar(
        title: Text(chapterTitle),
        actions: [
          PopupMenuButton<_ReaderMode>(
            initialValue: _readerMode,
            onSelected: (mode) =>
                _switchReaderMode(mode, _latestContentItems.length),
            itemBuilder: (context) => [
              PopupMenuItem<_ReaderMode>(
                value: _ReaderMode.verticalScroll,
                child: const Text('上下滑動'),
              ),
              PopupMenuItem<_ReaderMode>(
                value: _ReaderMode.horizontalPaging,
                child: const Text('左右翻頁'),
              ),
            ],
            icon: const Icon(Icons.swap_horiz),
          ),
        ],
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _toggleBottomBar,
        onHorizontalDragEnd: (d) => _onHorizontalDragEnd(context, d, chapters),
        child: Stack(
          children: [
            Positioned.fill(child: _buildContentBody(context, l10n)),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                ignoring: !_showBottomBar,
                child: AnimatedSlide(
                  duration: const Duration(milliseconds: 180),
                  offset: _showBottomBar ? Offset.zero : const Offset(0, 1),
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 180),
                    opacity: _showBottomBar ? 1 : 0,
                    child: ReaderBottomBar(
                      chapters: chapters,
                      currentIndex: currentIdx,
                      isSwitchingChapter: _isSwitchingChapter,
                      onPrevious: () =>
                          _jumpToChapter(context, chapters, currentIdx - 1),
                      onNext: () =>
                          _jumpToChapter(context, chapters, currentIdx + 1),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContentBody(BuildContext context, AppLocalizations l10n) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_hasError && _isContentEmpty) {
      return ErrorState(
        title: l10n.readerLoadError,
        message: _loadError.toString(),
        onRetry: _ensureLoaded,
        retryLabel: l10n.bookDetailRetry,
      );
    }

    if (_isContentEmpty) {
      return EmptyState(
        icon: Icons.menu_book_outlined,
        title: l10n.readerEmpty,
      );
    }

    if (_readerMode == _ReaderMode.verticalScroll) {
      return ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(
          LanghuanTheme.spaceLg,
          LanghuanTheme.spaceLg,
          LanghuanTheme.spaceLg,
          LanghuanTheme.space2xl,
        ),
        itemCount: _latestContentItems.length,
        itemBuilder: (context, index) {
          final item = _latestContentItems[index];
          return Padding(
            padding: EdgeInsets.only(
              bottom: item is ParagraphContentImage
                  ? LanghuanTheme.spaceLg
                  : LanghuanTheme.spaceMd,
            ),
            child: ParagraphView(item: item),
          );
        },
      );
    }

    return PageView.builder(
      controller: _pageController,
      itemCount: _latestContentItems.length,
      onPageChanged: _onPageChanged,
      itemBuilder: (context, index) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          LanghuanTheme.spaceLg,
          LanghuanTheme.spaceLg,
          LanghuanTheme.spaceLg,
          LanghuanTheme.space2xl,
        ),
        child: ParagraphView(item: _latestContentItems[index]),
      ),
    );
  }
}

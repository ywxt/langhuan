import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/error_state.dart';
import '../feeds/feed_service.dart';
import 'bookmark_provider.dart';
import 'book_providers.dart';
import 'reader_settings_provider.dart';
import 'reading_progress_provider.dart';
import 'widgets/reader_bottom_bar.dart';
import 'widgets/reader_top_bar.dart';

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
  bool _isInitializing = false;
  Object? _initError;
  List<ChapterInfoModel> _chapters = const [];
  bool _showControls = false;
  bool _isRefreshingChapter = false;
  late final ReadingProgressNotifier _progressNotifier;

  @override
  void initState() {
    super.initState();
    _progressNotifier = ref.read(readingProgressProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _initializeBook();
    });
  }

  Future<void> _initializeBook() async {
    if (widget.feedId.isEmpty || widget.bookId.isEmpty) return;

    setState(() {
      _isInitializing = true;
      _initError = null;
    });

    try {
      final chapters = await FeedService.instance
          .chapters(feedId: widget.feedId, bookId: widget.bookId)
          .toList();

      final fallbackChapterId = _resolveInitialChapterId(chapters);
      final fallbackParagraphIndex = fallbackChapterId == widget.chapterId
          ? widget.paragraphIndex
          : 0;

      await _progressNotifier.load(
        feedId: widget.feedId,
        bookId: widget.bookId,
        fallbackChapterId: fallbackChapterId,
        fallbackParagraphIndex: fallbackParagraphIndex,
      );

      if (!mounted) return;

      final activeId = ref.read(readingProgressProvider).activeChapterId;
      if (chapters.isNotEmpty && !chapters.any((c) => c.id == activeId)) {
        _progressNotifier.setActiveChapter(chapters.first.id);
      }

      setState(() {
        _chapters = chapters;
        _isInitializing = false;
      });

      unawaited(
        ref
            .read(bookInfoProvider.notifier)
            .load(feedId: widget.feedId, bookId: widget.bookId),
      );
      unawaited(
        ref
            .read(bookmarkProvider.notifier)
            .load(feedId: widget.feedId, bookId: widget.bookId),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isInitializing = false;
        _initError = error;
      });
    }
  }

  String _resolveInitialChapterId(List<ChapterInfoModel> chapters) {
    if (widget.chapterId.isNotEmpty &&
        chapters.any((chapter) => chapter.id == widget.chapterId)) {
      return widget.chapterId;
    }
    if (chapters.isNotEmpty) {
      return chapters.first.id;
    }
    return '';
  }

  void _toggleControls() {
    setState(() {
      _showControls = !_showControls;
    });
  }

  void _jumpToChapter(String chapterId, {int paragraphIndex = 0}) {
    _progressNotifier.setActiveChapter(
      chapterId,
      paragraphIndex: paragraphIndex,
    );
    unawaited(_progressNotifier.saveActive());
  }


  Future<void> _refreshCurrentChapter(String chapterId) async {
    if (_isRefreshingChapter || chapterId.isEmpty) return;

    setState(() {
      _isRefreshingChapter = true;
    });
    try {
      await FeedService.instance
          .paragraphs(
            feedId: widget.feedId,
            bookId: widget.bookId,
            chapterId: chapterId,
            forceRefresh: true,
          )
          .drain<void>();
    } finally {
      if (mounted) {
        setState(() {
          _isRefreshingChapter = false;
        });
      }
    }
  }

  Future<void> _addBookmark({
    required String chapterId,
    required int paragraphIndex,
  }) async {
    if (chapterId.isEmpty) return;
    final created = await ref
        .read(bookmarkProvider.notifier)
        .add(
          feedId: widget.feedId,
          bookId: widget.bookId,
          chapterId: chapterId,
          paragraphIndex: paragraphIndex,
          paragraphName: '',
          paragraphPreview: '',
        );
    if (!mounted || created == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).readerBookmarkAdded)),
    );
  }

  Future<void> _openBookmarkSheet() async {
    final l10n = AppLocalizations.of(context);
    await ref
        .read(bookmarkProvider.notifier)
        .load(feedId: widget.feedId, bookId: widget.bookId);
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final bookmarks = ref.watch(bookmarkProvider).items;
          if (bookmarks.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(LanghuanTheme.spaceLg),
              child: Center(child: Text(l10n.readerNoBookmarks)),
            );
          }

          return ListView.builder(
            shrinkWrap: true,
            itemCount: bookmarks.length,
            itemBuilder: (context, index) {
              final item = bookmarks[index];
              final chapterIndex = _chapters.indexWhere(
                (c) => c.id == item.chapterId,
              );
              final chapterTitle = chapterIndex >= 0
                  ? _chapters[chapterIndex].title
                  : item.chapterId;
              return ListTile(
                title: Text(chapterTitle),
                subtitle: Text(
                  item.paragraphName.trim().isEmpty
                      ? l10n.readerBookmarkParagraph(item.paragraphIndex + 1)
                      : item.paragraphName,
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  _jumpToChapter(
                    item.chapterId,
                    paragraphIndex: item.paragraphIndex,
                  );
                },
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    await ref.read(bookmarkProvider.notifier).remove(item.id);
                    if (!mounted) return;
                    ScaffoldMessenger.of(this.context).showSnackBar(
                      SnackBar(content: Text(l10n.readerBookmarkRemoved)),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _openTocSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => ListView.builder(
        itemCount: _chapters.length,
        itemBuilder: (context, index) {
          final chapter = _chapters[index];
          return ListTile(
            leading: Text('${index + 1}'),
            title: Text(chapter.title),
            onTap: () {
              Navigator.of(context).pop();
              _jumpToChapter(chapter.id);
            },
          );
        },
      ),
    );
  }

  Future<void> _openInterfaceSheet() async {
    final l10n = AppLocalizations.of(context);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final settings = ref.watch(readerSettingsProvider);
          final notifier = ref.read(readerSettingsProvider.notifier);

          return StatefulBuilder(
            builder: (context, setModalState) {
              return SingleChildScrollView(
                padding: const EdgeInsets.all(LanghuanTheme.spaceLg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      l10n.readerInterface,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: LanghuanTheme.spaceMd),
                    SegmentedButton<ReaderMode>(
                      segments: [
                        ButtonSegment(
                          value: ReaderMode.verticalScroll,
                          label: Text(l10n.readerModeVertical),
                          icon: const Icon(Icons.swap_vert),
                        ),
                        ButtonSegment(
                          value: ReaderMode.horizontalPaging,
                          label: Text(l10n.readerModeHorizontal),
                          icon: const Icon(Icons.swap_horiz),
                        ),
                      ],
                      selected: {settings.mode},
                      onSelectionChanged: (set) {
                        notifier.setMode(set.first);
                        setModalState(() {});
                      },
                    ),
                    const SizedBox(height: LanghuanTheme.spaceMd),
                    Text('Font ${settings.fontScale.toStringAsFixed(2)}x'),
                    Slider(
                      value: settings.fontScale,
                      min: 0.8,
                      max: 1.8,
                      divisions: 10,
                      onChanged: (v) {
                        notifier.setFontScale(v);
                        setModalState(() {});
                      },
                    ),
                    const SizedBox(height: LanghuanTheme.spaceSm),
                    Text(
                      'Line Height ${settings.lineHeight.toStringAsFixed(2)}',
                    ),
                    Slider(
                      value: settings.lineHeight,
                      min: 1.2,
                      max: 2.4,
                      divisions: 12,
                      onChanged: (v) {
                        notifier.setLineHeight(v);
                        setModalState(() {});
                      },
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final settings = ref.watch(readerSettingsProvider);
    final reading = ref.watch(readingProgressProvider);
    final baseTheme = Theme.of(context);
    final readerTheme = resolveReaderTheme(baseTheme, settings.themeMode);

    if (widget.feedId.isEmpty || widget.bookId.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.readerTitle)),
        body: EmptyState(
          icon: Icons.info_outline,
          title: l10n.readerMissingParams,
        ),
      );
    }

    if (_isInitializing) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.readerTitle)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_initError != null && _chapters.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.readerTitle)),
        body: ErrorState(
          title: l10n.readerLoadError,
          message: _initError.toString(),
          onRetry: _initializeBook,
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

    final activeChapterId = reading.activeChapterId.isEmpty
        ? _chapters.first.id
        : reading.activeChapterId;
    final activeParagraphIndex = reading.activeParagraphIndex;

    final currentIdx = _chapters
        .indexWhere((c) => c.id == activeChapterId)
        .clamp(0, _chapters.length - 1);
    final chapterTitle = _chapters[currentIdx].title;

    final mediaQuery = MediaQuery.of(context);
    final topPadding = mediaQuery.padding.top;
    final brightness = readerTheme.brightness;
    final overlayStyle = brightness == Brightness.dark
        ? SystemUiOverlayStyle.light
        : SystemUiOverlayStyle.dark;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: Theme(
        data: readerTheme,
        child: Scaffold(
          extendBody: true,
          extendBodyBehindAppBar: true,
          body: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _toggleControls,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Center(
                    child: Text(
                      l10n.readerTitle,
                      style: readerTheme.textTheme.bodyLarge,
                    ),
                  ),
                ),
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
                        child: ReaderTopBar(
                          topPadding: topPadding,
                          chapterTitle: chapterTitle,
                          backgroundColor:
                              readerTheme.colorScheme.surfaceContainer,
                          titleTextStyle: readerTheme.textTheme.titleMedium,
                          bookmarksTooltip: l10n.readerBookmarks,
                          addBookmarkTooltip: l10n.readerBookmarkAddHint,
                          refreshTooltip: l10n.readerRefreshChapter,
                          isRefreshing: _isRefreshingChapter,
                          onBack: () => Navigator.of(context).pop(),
                          onOpenBookmarks: _openBookmarkSheet,
                          onAddBookmark: () => _addBookmark(
                            chapterId: activeChapterId,
                            paragraphIndex: activeParagraphIndex,
                          ),
                          onRefresh: () =>
                              _refreshCurrentChapter(activeChapterId),
                        ),
                      ),
                    ),
                  ),
                ),
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
                          isSwitchingChapter: _isRefreshingChapter,
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
                          onOpenToc: _openTocSheet,
                          onOpenInterface: _openInterfaceSheet,
                          onOpenSettings: () {},
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../reader_gesture_binding.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/utils/app_log.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/error_state.dart';
import '../../shared/widgets/loading.dart';
import '../../src/rust/api/types.dart';
import '../feeds/feed_providers.dart';
import '../feeds/feed_service.dart';
import 'comments/comments_controller.dart';
import 'comments/comments_panel.dart';
import 'listening/listening_controller.dart';
import 'listening/listening_panel.dart';
import 'reader_screen_controller.dart';
import 'reader_settings_provider.dart';
import 'reading_progress_provider.dart';
import 'widgets/chapter_content_manager.dart';
import 'widgets/reader_controller.dart';
import 'widgets/reader_feedback.dart';
import 'widgets/reader_frame_monitor.dart';
import 'widgets/reader_overlays.dart';
import 'widgets/reader_sheets.dart';
import 'widgets/reader_status_bar.dart';
import 'widgets/reader_types.dart';

class ReaderPage extends ConsumerStatefulWidget {
  const ReaderPage({
    super.key,
    required this.feedId,
    required this.bookId,
    required this.chapterId,
    this.paragraphId = '',
  });

  final String feedId;
  final String bookId;
  final String chapterId;
  final String paragraphId;

  @override
  ConsumerState<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends ConsumerState<ReaderPage> {
  late final ReaderController _readerController;
  late final ReaderScreenController _screenController;
  ReaderFrameMonitor? _frameMonitor;
  bool _chapterComments = false, _paragraphComments = false;
  late final ListeningController _listening;
  String _followingParagraph = '';

  /// Live page progress of the active chapter, fed by the content manager
  /// and rendered by the bottom status bar.
  final ValueNotifier<ReaderPageProgress?> _pageProgress = ValueNotifier(null);

  @override
  void initState() {
    super.initState();
    _readerController = ReaderController();
    _listening = ref.read(listeningControllerProvider);
    _listening.addListener(_onListeningChanged);
    _screenController = ReaderScreenController(
      ref: ref,
      readerController: _readerController,
      feedId: widget.feedId,
      bookId: widget.bookId,
      initialChapterId: widget.chapterId,
      initialParagraphId: widget.paragraphId,
    );
    _screenController.addListener(_onScreenControllerChanged);
    _readerController.onPositionChanged = (position) {
      if (!_listening.ownsBook(widget.feedId, widget.bookId)) {
        _screenController.onPositionChanged(position);
      } else {
        // Keep the visible position current without competing with TTS's
        // atomic listening/reading progress writes.
        ref
            .read(readingProgressProvider.notifier)
            .setActivePosition(
              chapterId: position.chapterId,
              paragraphId: position.paragraphId,
              paragraphOffset: position.paragraphOffset,
              paragraphCharOffset: position.charOffset,
            );
      }
    };
    _loadCommentSupport();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _screenController.initialize();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final display = View.of(context).display;
    final monitor = _frameMonitor;
    if (monitor == null) {
      _frameMonitor = ReaderFrameMonitor(refreshRate: display.refreshRate)
        ..start();
      AppLog.info(
        'reader.lifecycle',
        'reader opened',
        fields: {
          'feed_id': widget.feedId,
          'book_id': widget.bookId,
          'chapter_id': widget.chapterId,
          'display_hz': display.refreshRate.toStringAsFixed(1),
          'physical_width': display.size.width.toInt(),
          'physical_height': display.size.height.toInt(),
          'device_pixel_ratio': display.devicePixelRatio.toStringAsFixed(2),
        },
      );
    } else {
      monitor.updateRefreshRate(display.refreshRate);
    }
  }

  @override
  void dispose() {
    _listening.removeListener(_onListeningChanged);
    _frameMonitor?.stop();
    AppLog.info(
      'reader.lifecycle',
      'reader closed',
      fields: {'feed_id': widget.feedId, 'book_id': widget.bookId},
    );
    _screenController.removeListener(_onScreenControllerChanged);
    _screenController.dispose();
    _readerController.onPositionChanged = null;
    _readerController.dispose();
    _pageProgress.dispose();
    super.dispose();
  }

  void _onScreenControllerChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _toggleControls() {
    _screenController.toggleControls();
  }

  void _onParagraphLongPress(
    String chapterId,
    String paragraphId,
    ParagraphContent paragraph,
    Rect globalRect,
  ) {
    _pauseForManualReading();
    _screenController.setSelection(
      chapterId: chapterId,
      paragraphId: paragraphId,
      paragraph: paragraph,
      globalRect: globalRect,
    );
  }

  void _clearSelection() {
    _screenController.clearSelection();
  }

  Future<void> _loadCommentSupport() async {
    try {
      final support = await ref
          .read(feedServiceProvider)
          .commentSupport(widget.feedId);
      if (mounted) {
        setState(() {
          _chapterComments = support.chapter;
          _paragraphComments = support.paragraph;
        });
      }
    } catch (_) {
      /* Invalid and disabled sources expose no comment actions. */
    }
  }

  void _onListeningChanged() {
    if (!mounted) return;
    if (_listening.ownsBook(widget.feedId, widget.bookId) &&
        _listening.paragraphId.isNotEmpty) {
      _screenController.suspendProgressSaving();
      final key = '${_listening.chapterId}:${_listening.paragraphId}';
      if (_followingParagraph != key) {
        _followingParagraph = key;
        _readerController.jumpTo(
          chapterId: _listening.chapterId,
          paragraphId: _listening.paragraphId,
        );
      }
    } else {
      _followingParagraph = '';
    }
    setState(() {});
  }

  void _pauseForManualReading() {
    if (_listening.ownsBook(widget.feedId, widget.bookId)) _listening.pause();
  }

  Widget _observeReadingGestures(Widget child) => Listener(
    onPointerSignal: (_) {
      _pauseForManualReading();
      _screenController.hideControls();
    },
    onPointerPanZoomStart: (_) {
      _pauseForManualReading();
      _screenController.hideControls();
    },
    child: NotificationListener<ScrollStartNotification>(
      onNotification: (notification) {
        if (notification.dragDetails != null) {
          _pauseForManualReading();
          _screenController.hideControls();
        }
        return false;
      },
      child: child,
    ),
  );

  Future<void> _openComments(String chapterId, {String? paragraphId}) {
    // Clearing the paragraph selection rebuilds the reader; deferring that
    // by one frame keeps the tap frame free for the panel's entrance
    // animation instead of hitching it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _clearSelection();
    });
    return showCommentsPanel(
      context,
      CommentsController(
        ref.read(feedServiceProvider),
        feedId: widget.feedId,
        bookId: widget.bookId,
        chapterId: chapterId,
        paragraphId: paragraphId,
      ),
    );
  }

  /// Badge tap on a commented paragraph (or the chapter title, whose source
  /// id addresses the chapter-comment unit). Only source-identity
  /// paragraphs carry badges, so a missing source id is unreachable in
  /// practice; guard anyway.
  void _openParagraphComments(String chapterId, ParagraphContent paragraph) {
    final sourceId = paragraph.id.sourceId;
    if (sourceId == null) return;
    unawaited(_openComments(chapterId, paragraphId: sourceId));
  }

  Future<void> _openListening() => showListeningPanel(
    context,
    _listening,
    onStart: () {
      final progress = ref.read(readingProgressProvider);
      _listening.start(
        feedId: widget.feedId,
        bookId: widget.bookId,
        chapterId: progress.activeChapterId,
        paragraphId: progress.activeParagraphId,
      );
    },
  );

  // ── Sheet and navigation actions (formerly ReaderPageActions) ────────────

  void _jumpToChapter(String chapterId, {String paragraphId = ''}) {
    if (_listening.ownsBook(widget.feedId, widget.bookId)) _listening.pause();
    _screenController.jumpToChapter(chapterId, paragraphId: paragraphId);
  }

  Future<void> _addBookmark(ParagraphSelection selection) async {
    final created = await _screenController.addBookmark(
      chapterId: selection.chapterId,
      paragraphId: selection.paragraphId,
      paragraph: selection.paragraph,
    );
    if (!created) return;

    if (!mounted) return;
    showReaderToast(context, AppLocalizations.of(context).readerBookmarkAdded);
  }

  Future<void> _openBookmarkSheet() async {
    await showReaderBookmarkSheet(
      context: context,
      ref: ref,
      feedId: widget.feedId,
      bookId: widget.bookId,
      chapters: _screenController.chapters,
      onJumpToParagraph: (chapterId, paragraphId) {
        _jumpToChapter(chapterId, paragraphId: paragraphId);
      },
      onBookmarkRemoved: () {
        showReaderToast(
          context,
          AppLocalizations.of(context).readerBookmarkRemoved,
        );
      },
    );
  }

  Future<void> _openTocSheet() {
    return showReaderTocSheet(
      context: context,
      ref: ref,
      chapters: _screenController.chapters,
      onJumpToChapter: (chapterId) {
        _screenController.hideControls();
        _jumpToChapter(chapterId);
      },
    );
  }

  Future<void> _openInterfaceSheet() {
    return showReaderInterfaceSheet(context);
  }

  Future<void> _openSettingsSheet() {
    return showReaderSettingsSheet(context);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final settings = ref.watch(readerSettingsProvider);
    final activeChapterId = ref.watch(
      readingProgressProvider.select((s) => s.activeChapterId),
    );
    final baseTheme = Theme.of(context);
    final readerTheme = resolveReaderTheme(
      baseTheme,
      settings.themeMode,
      systemBrightness: MediaQuery.platformBrightnessOf(context),
      customTheme: settings.customTheme,
    );

    if (widget.feedId.isEmpty || widget.bookId.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.readerTitle)),
        body: EmptyState(
          icon: Icons.info_outline,
          title: l10n.readerMissingParams,
        ),
      );
    }

    if (_screenController.isInitializing) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.readerTitle)),
        body: const LoadingState(),
      );
    }

    if (_screenController.initError != null &&
        _screenController.chapters.isEmpty) {
      final display = describeError(
        _screenController.initError,
        l10n,
        genericTitle: l10n.readerLoadError,
      );
      return Scaffold(
        appBar: AppBar(title: Text(l10n.readerTitle)),
        body: ErrorState(
          title: display.title,
          message: display.detail,
          onRetry: _screenController.initialize,
          retryLabel: l10n.bookDetailRetry,
        ),
      );
    }

    if (_screenController.chapters.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.readerTitle)),
        body: EmptyState(
          icon: Icons.menu_book_outlined,
          title: l10n.readerEmpty,
        ),
      );
    }

    final visibleChapterId = _listening.ownsBook(widget.feedId, widget.bookId)
        ? _listening.chapterId
        : activeChapterId;
    final effectiveChapterId = visibleChapterId.isEmpty
        ? _screenController.chapters.first.id
        : visibleChapterId;

    final currentIdx = _screenController.chapters
        .indexWhere((c) => c.id == effectiveChapterId)
        .clamp(0, _screenController.chapters.length - 1);
    final chapterTitle = _screenController.chapters[currentIdx].title;

    final mediaQuery = MediaQuery.of(context);
    final topPadding = mediaQuery.padding.top;
    // The transparent bottom status line (plus the safe-area inset) stays
    // clear of reading content: pages end above it and the vertical reader's
    // viewport is inset likewise.
    final bottomChrome =
        mediaQuery.viewPadding.bottom + ReaderStatusBar.reservedHeight;
    final brightness = readerTheme.brightness;
    // Icon contrast follows the reader theme; the bar itself stays
    // transparent (edge-to-edge, see main()) so it always matches the
    // reader surface.
    final baseStyle = brightness == Brightness.dark
        ? SystemUiOverlayStyle.light
        : SystemUiOverlayStyle.dark;
    final overlayStyle = baseStyle.copyWith(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarContrastEnforced: false,
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: Theme(
        data: readerTheme,
        child: Scaffold(
          extendBody: true,
          extendBodyBehindAppBar: true,
          body: _observeReadingGestures(
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _toggleControls,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ReaderInputRegion(
                      child: RepaintBoundary(
                        child: ChapterContentManager(
                          feedService: ref.read(feedServiceProvider),
                          feedId: widget.feedId,
                          bookId: widget.bookId,
                          chapters: _screenController.chapters,
                          controller: _readerController,
                          pageMode: settings.pageMode,
                          onToggleControls: _toggleControls,
                          onPageTurnStart: () {
                            _clearSelection();
                            _screenController.hideControls();
                            if (_listening.ownsBook(
                              widget.feedId,
                              widget.bookId,
                            )) {
                              _listening.pause();
                            }
                          },
                          onRefreshBook: _screenController.refreshChapters,
                          fontScale: settings.fontScale,
                          fontFamily: settings.fontFamily,
                          prewarmCustomFont:
                              settings.customFontFilePath != null &&
                              settings.fontFamily != null,
                          letterSpacing: settings.letterSpacing,
                          paragraphSpacing: settings.paragraphSpacing,
                          lineHeight: settings.lineHeight,
                          chineseConversion: settings.chineseConversion,
                          pageProgress: _pageProgress,
                          viewportBottomInset: bottomChrome,
                          contentPadding: EdgeInsets.fromLTRB(
                            LanghuanTheme.spaceLg,
                            topPadding + LanghuanTheme.spaceMd,
                            LanghuanTheme.spaceLg,
                            bottomChrome,
                          ),
                          onParagraphLongPress: _onParagraphLongPress,
                          selectedChapterId:
                              _screenController.selection?.chapterId ??
                              (_listening.ownsBook(widget.feedId, widget.bookId)
                                  ? _listening.chapterId
                                  : null),
                          selectedParagraphId:
                              _screenController.selection?.paragraphId ??
                              (_listening.ownsBook(widget.feedId, widget.bookId)
                                  ? _listening.paragraphId
                                  : null),
                          showComments: settings.showComments,
                          onParagraphComments: _openParagraphComments,
                        ),
                      ),
                    ),
                  ),
                  ReaderStatusBar(
                    visible: !_screenController.showControls,
                    theme: readerTheme,
                    chapterId: effectiveChapterId,
                    chapterTitle: chapterTitle,
                    chapterIndex: currentIdx,
                    chapterCount: _screenController.chapters.length,
                    pageProgress: _pageProgress,
                  ),
                  ReaderTopOverlay(
                    showControls: _screenController.showControls,
                    theme: readerTheme,
                    topPadding: topPadding,
                    chapterTitle: chapterTitle,
                    l10n: l10n,
                    isRefreshing: _screenController.isRefreshingChapter,
                    onBack: () => Navigator.of(context).pop(),
                    onOpenBookmarks: _openBookmarkSheet,
                    onRefresh: () {
                      if (_listening.ownsBook(widget.feedId, widget.bookId)) {
                        _listening.pause();
                      }
                      _screenController.refreshCurrentChapter(
                        effectiveChapterId,
                      );
                    },
                    additionalActions: [
                      if (_chapterComments || _paragraphComments)
                        IconButton(
                          tooltip: settings.showComments
                              ? l10n.readerHideComments
                              : l10n.readerShowComments,
                          icon: Icon(
                            settings.showComments
                                ? Icons.chat_bubble
                                : Icons.chat_bubble_outline,
                          ),
                          onPressed: () => ref
                              .read(readerSettingsProvider.notifier)
                              .setShowComments(!settings.showComments),
                        ),
                      if (_chapterComments)
                        IconButton(
                          tooltip: l10n.readerChapterComments,
                          icon: const Icon(Icons.forum_outlined),
                          onPressed: () => _openComments(effectiveChapterId),
                        ),
                      IconButton(
                        tooltip: l10n.listeningTitle,
                        icon: const Icon(Icons.headphones),
                        onPressed: _openListening,
                      ),
                    ],
                  ),
                  ReaderBottomOverlay(
                    showControls: _screenController.showControls,
                    chapters: _screenController.chapters,
                    currentIndex: currentIdx,
                    isSwitchingChapter: _screenController.isRefreshingChapter,
                    onPrevious: () {
                      if (currentIdx > 0) {
                        _jumpToChapter(
                          _screenController.chapters[currentIdx - 1].id,
                        );
                      }
                    },
                    onNext: () {
                      if (currentIdx < _screenController.chapters.length - 1) {
                        _jumpToChapter(
                          _screenController.chapters[currentIdx + 1].id,
                        );
                      }
                    },
                    onOpenToc: _openTocSheet,
                    onOpenInterface: _openInterfaceSheet,
                    onOpenSettings: _openSettingsSheet,
                  ),
                  if (_screenController.selection != null)
                    ReaderSelectionOverlay(
                      selection: _screenController.selection!,
                      theme: readerTheme,
                      l10n: l10n,
                      onAddBookmark: () {
                        final sel = _screenController.selection;
                        if (sel == null) return;
                        _addBookmark(sel);
                        _clearSelection();
                      },
                      onComments:
                          _paragraphComments &&
                              paragraphIdFromString(
                                    _screenController.selection!.paragraphId,
                                  )?.sourceId !=
                                  null
                          ? () => _openComments(
                              _screenController.selection!.chapterId,
                              paragraphId: paragraphIdFromString(
                                _screenController.selection!.paragraphId,
                              )?.sourceId,
                            )
                          : null,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

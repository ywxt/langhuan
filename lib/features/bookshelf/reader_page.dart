import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/error_state.dart';
import '../../shared/widgets/loading.dart';
import '../../src/rust/api/types.dart';
import '../feeds/feed_providers.dart';
import 'reader_screen_controller.dart';
import 'reader_settings_provider.dart';
import 'reading_progress_provider.dart';
import 'widgets/chapter_content_manager.dart';
import 'widgets/reader_controller.dart';
import 'widgets/reader_feedback.dart';
import 'widgets/reader_overlays.dart';
import 'widgets/reader_sheets.dart';
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

  @override
  void initState() {
    super.initState();
    _readerController = ReaderController();
    _screenController = ReaderScreenController(
      ref: ref,
      readerController: _readerController,
      feedId: widget.feedId,
      bookId: widget.bookId,
      initialChapterId: widget.chapterId,
      initialParagraphId: widget.paragraphId,
    );
    _screenController.addListener(_onScreenControllerChanged);
    _readerController.onPositionChanged = _screenController.onPositionChanged;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _screenController.initialize();
    });
  }

  @override
  void dispose() {
    _screenController.removeListener(_onScreenControllerChanged);
    _screenController.dispose();
    _readerController.onPositionChanged = null;
    _readerController.dispose();
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

  // ── Sheet and navigation actions (formerly ReaderPageActions) ────────────

  void _jumpToChapter(String chapterId, {String paragraphId = ''}) {
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

    final effectiveChapterId = activeChapterId.isEmpty
        ? _screenController.chapters.first.id
        : activeChapterId;

    final currentIdx = _screenController.chapters
        .indexWhere((c) => c.id == effectiveChapterId)
        .clamp(0, _screenController.chapters.length - 1);
    final chapterTitle = _screenController.chapters[currentIdx].title;

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
                  child: RepaintBoundary(
                    child: ChapterContentManager(
                      feedService: ref.read(feedServiceProvider),
                      feedId: widget.feedId,
                      bookId: widget.bookId,
                      chapters: _screenController.chapters,
                      controller: _readerController,
                      pageMode: settings.pageMode,
                      onToggleControls: _toggleControls,
                      fontScale: settings.fontScale,
                      fontFamily: settings.fontFamily,
                      letterSpacing: settings.letterSpacing,
                      paragraphSpacing: settings.paragraphSpacing,
                      lineHeight: settings.lineHeight,
                      chineseConversion: settings.chineseConversion,
                      contentPadding: EdgeInsets.fromLTRB(
                        LanghuanTheme.spaceLg,
                        topPadding + LanghuanTheme.spaceMd,
                        LanghuanTheme.spaceLg,
                        LanghuanTheme.spaceLg,
                      ),
                      onParagraphLongPress: _onParagraphLongPress,
                      selectedChapterId: _screenController.selection?.chapterId,
                      selectedParagraphId:
                          _screenController.selection?.paragraphId,
                    ),
                  ),
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
                    _screenController.refreshCurrentChapter(effectiveChapterId);
                  },
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
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/loading.dart';
import '../../../src/rust/api/types.dart';
import '../../feeds/feed_service.dart';
import '../comments/chapter_end_comments.dart';
import '../comments/comments_controller.dart';
import '../reader_settings_provider.dart' show ReaderPageMode;
import 'horizontal_reader_view.dart';
import 'page_breaker.dart';
import 'comment_badge.dart';
import 'reader_chapter_window.dart';
import 'reader_controller.dart';
import 'reader_glyph_warmup.dart';
import 'reader_typography.dart';
import 'reader_types.dart';
import 'seamless_vertical_reader.dart';

/// Wires the shared [ReaderChapterWindow] into the active reader view.
///
/// * **Vertical** mode renders [SeamlessVerticalReader] — seamless scroll
///   across chapter boundaries.
/// * **Horizontal** mode concatenates the window chapters' pages into one
///   flat, cross-chapter page list; [HorizontalReaderView] walks it by
///   index, so turning past a chapter boundary is just an index change.
///
/// The canonical horizontal position is `(chapterId, localPageIndex)` and is
/// re-resolved against the flat list on every rebuild, which makes it immune
/// to entries being added/removed by window expansion, trimming or reloads.
class ChapterContentManager extends StatefulWidget {
  const ChapterContentManager({
    super.key,
    required this.feedService,
    required this.feedId,
    required this.bookId,
    required this.chapters,
    required this.controller,
    required this.pageMode,
    required this.onToggleControls,
    this.onPageTurnStart,
    this.onRefreshBook,
    required this.fontScale,
    this.fontFamily,
    this.prewarmCustomFont = false,
    this.letterSpacing = 0.0,
    this.paragraphSpacing = LanghuanTheme.spaceMd,
    required this.lineHeight,
    required this.contentPadding,
    this.transformerRevision = '',
    this.paginationSliceBudget = const Duration(milliseconds: 4),
    this.onParagraphLongPress,
    this.selectedChapterId,
    this.selectedParagraphId,
    this.showComments = true,
    this.showChapterComments = false,
    this.onParagraphComments,
    this.pageProgress,
    this.viewportTopInset = 0,
    this.viewportBottomInset = 0,
  });

  /// Chapter paragraph source. Injected so tests can supply a fake and the
  /// widget never reaches for the app-wide singleton.
  final FeedService feedService;
  final String feedId;
  final String bookId;
  final List<ChapterInfoModel> chapters;
  final ReaderController controller;
  final ReaderPageMode pageMode;
  final VoidCallback onToggleControls;
  final VoidCallback? onPageTurnStart;
  final Future<void> Function()? onRefreshBook;
  final double fontScale;
  final String? fontFamily;
  final bool prewarmCustomFont;
  final double letterSpacing;
  final double paragraphSpacing;
  final double lineHeight;
  final EdgeInsets contentPadding;
  final String transformerRevision;

  /// Per-frame time budget for incremental pagination (horizontal mode).
  /// Tests inject [Duration.zero] to make one paragraph paginate per frame,
  /// which makes the loading-mask lifecycle observable deterministically.
  final Duration paginationSliceBudget;
  final void Function(
    String chapterId,
    String paragraphId,
    ParagraphContent paragraph,
    Rect globalRect,
  )?
  onParagraphLongPress;
  final String? selectedChapterId;
  final String? selectedParagraphId;

  /// Whether commented paragraphs show their comment badge and intercept
  /// taps to open the comments. The reader-level switch; only meaningful
  /// for feeds whose script reports paragraph comment counts.
  ///
  /// Layout never depends on this: pagination always reserves badge space
  /// while [onParagraphComments] exists, so flipping the switch only stops
  /// badges from rendering — pages, line grid and reading position stay
  /// exactly where they were.
  final bool showComments;

  /// Whether each chapter ends with its inline chapter-comment section.
  /// The reader-level switch; only meaningful for feeds whose script
  /// exposes chapter comments. Toggling it never re-pages text: pages keep
  /// their identity and the section appears or disappears after the
  /// chapter's last page.
  final bool showChapterComments;

  /// Opens a paragraph's comments (badge tap). Null disables badges.
  final void Function(String chapterId, ParagraphContent paragraph)?
  onParagraphComments;

  /// Live progress of the active chapter, written by this manager as the
  /// position moves: page units while paging horizontally, paragraph units
  /// while scrolling vertically. Owned by the parent (the reader chrome);
  /// null skips publishing entirely.
  final ValueNotifier<ReaderChapterProgress?>? pageProgress;

  /// System status-bar height kept clear of the vertical scroll viewport.
  /// Horizontal mode uses its content padding for this instead.
  final double viewportTopInset;

  /// Height of persistent bottom chrome (the reader status bar) that
  /// vertical-mode content must not scroll beneath. Horizontal mode needs
  /// no such inset: its content padding already ends above the chrome.
  final double viewportBottomInset;

  @override
  State<ChapterContentManager> createState() => _ChapterContentManagerState();
}

/// One entry of the flat horizontal page list.
class _FlatEntry {
  const _FlatEntry({
    required this.chapterId,
    required this.localPageIndex,
    required this.loading,
    this.error,
    this.chapterEnd = false,
  });

  final String chapterId;

  /// Index of the page within its chapter, or -1 for a placeholder entry
  /// (neighbor chapter still loading / failed). A [chapterEnd] entry uses
  /// the page count — one past the last text page.
  final int localPageIndex;
  final bool loading;

  /// True for the chapter-end comments entry following a chapter's pages.
  final bool chapterEnd;

  /// Failure cause when this entry stands in for a failed chapter.
  final Object? error;
}

class _ChapterContentManagerState extends State<ChapterContentManager> {
  ReaderChapterWindow? _window;
  final ReaderGlyphWarmup _glyphWarmup = ReaderGlyphWarmup();

  PageBreaker? _breaker;
  TextTheme? _layoutTextTheme;
  TextScaler? _layoutTextScaler;
  Locale? _layoutLocale;
  TextDirection? _layoutDirection;
  Size _lastPageSize = Size.zero;
  final Map<String, List<PageContent>> _pagesByChapter = {};

  /// In-flight chunked paginations. Entering the reader can load several
  /// chapters at once; paginating them all inside one build froze the UI
  /// for hundreds of milliseconds (badge-dense chapters especially), so in
  /// horizontal mode each chapter paginates incrementally — a few
  /// milliseconds per frame — while the reader shows loading slots.
  final Map<String, PaginationJob> _paginationJobs = {};
  bool _paginationSliceScheduled = false;

  /// Chapters whose cached pages match the current breaker configuration.
  /// A typography change keeps stale pages displayed (the old
  /// clear-and-mask path would flash a loading slot on every live commit
  /// during slider drags), but only chapters in this set may answer jumps
  /// and estimates — stale page boundaries are preview-only.
  final Set<String> _freshPages = {};

  /// Per-chapter comment-badge paragraph identity sets. Depends only on
  /// paragraph identity and counts — typography changes keep it; chapter
  /// reloads and conversion changes invalidate it (mirrors
  /// [_pagesByChapter], minus the typography case).
  final Map<String, Set<String>> _badgeIdsByChapter = {};

  /// Chapter-comment controllers for the inline chapter-end sections.
  /// Created only while [ChapterContentManager.showChapterComments] is on;
  /// pruned to the reading window so trimmed chapters release their pages.
  ChapterCommentsCache? _chapterComments;

  // Canonical horizontal position.
  String _activeChapterId = '';
  int _activeLocalPageIndex = 0;
  final _verticalReaderKey = GlobalKey<SeamlessVerticalReaderState>();
  String _pendingJumpParagraphId = '';
  int _pendingJumpCharOffset = 0;

  // Vertical scroll target (token distinguishes consecutive commands).
  int _scrollToken = 0;
  ReaderScrollTarget? _verticalTarget;

  /// True while the current [_verticalTarget] still needs a page estimate
  /// that pagination has not produced yet. The reader holds its offset in
  /// the meantime; [_completePaginationJob] re-issues the target (fresh
  /// token) once the chapter's pages are complete. Cleared when an
  /// estimate answers or the reader reports an exact landing.
  bool _verticalEstimatePending = false;

  /// A page-progress publish is pending for the end of the current frame.
  bool _pageProgressPublishScheduled = false;

  String _lastReportedChapterId = '';
  String _lastReportedParagraphId = '';
  int _lastReportedCharOffset = 0;

  @override
  void initState() {
    super.initState();

    final startId =
        widget.controller.pendingChapterId ??
        (widget.chapters.isNotEmpty ? widget.chapters.first.id : '');
    final pendingParagraphId = widget.controller.pendingParagraphId;
    final pendingCharOffset = widget.controller.pendingCharOffset;
    widget.controller.consumeJump();
    widget.controller.addListener(_onControllerCommand);
    widget.controller.isParagraphVisible = _isParagraphVisible;
    widget.controller.onCancelPendingNavigation = _cancelPendingNavigation;

    _activeChapterId = startId;
    _pendingJumpParagraphId = pendingParagraphId;
    _pendingJumpCharOffset = pendingCharOffset;
    _issueVerticalTarget(chapterId: startId, paragraphId: pendingParagraphId);

    _window = ReaderChapterWindow(
      chapters: widget.chapters,
      anchorChapterId: startId,
      loader: _loadChapterParagraphs,
      maxWindowChapters: 8,
    );
    _window!.addListener(_onWindowChanged);

    // The pagination machinery's first use pays one-time costs — the badge
    // label style's first layout, body-text shaping for this breaker's font
    // configuration, and the placeholder-span path a badged paragraph takes
    // (~20ms combined in debug). Left alone, that lands in the first
    // pagination slice after entry and blows its frame budget. Chapters are
    // still loading from the network now, so warming here hides the cost.
    // Pagination always reserves badge space while comment plumbing exists
    // (see [_layoutBadgeIdsOf]), so the visibility switch plays no part.
    if (widget.onParagraphComments != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _warmupPagination());
    }
  }

  /// Steps one synthetic badged paragraph through the real pagination path.
  void _warmupPagination() {
    if (!mounted || _breaker == null) return;
    final badgeSize = CommentBadge.inlineSize(context, 1);
    final job = _breaker!.startPagination(
      [
        ParagraphContent.text(
          id: ParagraphId(
            original: const OriginalParagraphId.source('__warmup__'),
            path: const [],
          ),
          content: '預',
          commentCount: 1,
        ),
      ],
      chapterId: '__warmup__',
      commentBadgeSizeOf: (_) => badgeSize,
    );
    while (!job.step(const Duration(seconds: 1))) {}
  }

  @override
  void dispose() {
    widget.controller.isParagraphVisible = null;
    widget.controller.onCancelPendingNavigation = null;
    widget.controller.removeListener(_onControllerCommand);
    _window?.removeListener(_onWindowChanged);
    _window?.dispose();
    _paginationJobs.clear();
    _chapterComments?.clear();
    super.dispose();
  }

  Future<List<ParagraphContent>> _loadChapterParagraphs(
    String chapterId, {
    bool forceRefresh = false,
  }) async {
    final paragraphs = await widget.feedService.paragraphs(
      feedId: widget.feedId,
      bookId: widget.bookId,
      chapterId: chapterId,
      forceRefresh: forceRefresh,
    );
    if (mounted &&
        chapterId == _activeChapterId &&
        _pendingJumpParagraphId.isNotEmpty &&
        paragraphs.isNotEmpty) {
      final ids = paragraphs.map((p) => p.id.toStringValue()).toList();
      if (!ids.contains(_pendingJumpParagraphId)) {
        final resolved =
            ids
                .where(
                  (id) => sameOriginalParagraph(id, _pendingJumpParagraphId),
                )
                .firstOrNull ??
            ids.first;
        _pendingJumpParagraphId = resolved;
        _pendingJumpCharOffset = 0;
        _issueVerticalTarget(chapterId: chapterId, paragraphId: resolved);
      }
    }
    _scheduleGlyphWarmup(chapterId, paragraphs);
    return paragraphs;
  }

  void _scheduleGlyphWarmup(
    String chapterId,
    List<ParagraphContent> paragraphs,
  ) {
    if (!widget.prewarmCustomFont || widget.fontFamily == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.prewarmCustomFont) return;
      final theme = Theme.of(context);
      final family = widget.fontFamily;
      if (family == null) return;
      final width =
          MediaQuery.sizeOf(context).width - widget.contentPadding.horizontal;
      // The warmed glyphs must come from the same recipe the views paint
      // with, or the atlas warms variants the renderer never uses.
      final typo = ReaderTypography(
        textTheme: theme.textTheme,
        fontScale: widget.fontScale,
        fontFamily: family,
        letterSpacing: widget.letterSpacing,
        lineHeight: widget.lineHeight,
      );
      _glyphWarmup.schedule(
        chapterId: chapterId,
        paragraphs: paragraphs,
        bodyStyle: typo.body,
        titleStyle: typo.title,
        width: width,
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        textDirection: Directionality.of(context),
      );
    });
  }

  // ── Controller commands ─────────────────────────────────────────────────

  bool _isParagraphVisible(String chapterId, String paragraphId) {
    if (widget.pageMode == ReaderPageMode.vertical) {
      return _verticalReaderKey.currentState?.isParagraphVisible(
            chapterId,
            paragraphId,
          ) ??
          false;
    }
    if (_activeChapterId != chapterId) return false;
    final pages = _pagesFor(chapterId);
    if (_activeLocalPageIndex < 0 || _activeLocalPageIndex >= pages.length) {
      return false;
    }
    return pages[_activeLocalPageIndex].items.any(
      (item) => item.paragraphId == paragraphId,
    );
  }

  void _cancelPendingNavigation() {
    _pendingJumpParagraphId = '';
    _pendingJumpCharOffset = 0;
    _verticalEstimatePending = false;
    _verticalTarget = null;
    _verticalReaderKey.currentState?.cancelPendingNavigation();
  }

  void _onControllerCommand() {
    final reloadId = widget.controller.consumeChapterReload();
    if (reloadId != null && reloadId.isNotEmpty) {
      _onChapterReloadCommand(reloadId);
    }

    final targetId = widget.controller.pendingChapterId;
    if (targetId == null) return;
    final paragraphId = widget.controller.pendingParagraphId;
    final charOffset = widget.controller.pendingCharOffset;
    widget.controller.consumeJump();
    _onJumpCommand(targetId, paragraphId, charOffset);
  }

  void _onJumpCommand(String chapterId, String paragraphId, int charOffset) {
    _activeChapterId = chapterId;
    _activeLocalPageIndex = 0;
    _pendingJumpParagraphId = paragraphId;
    _pendingJumpCharOffset = charOffset;
    _issueVerticalTarget(chapterId: chapterId, paragraphId: paragraphId);

    _window!.jumpTo(chapterId);
    _reportPosition(chapterId, paragraphId, 0, charOffset);

    _resolveHorizontalPendingJump();
    setState(() {});
  }

  void _onChapterReloadCommand(String chapterId) {
    _pagesByChapter.remove(chapterId);
    _badgeIdsByChapter.remove(chapterId);
    _paginationJobs.remove(chapterId);
    _freshPages.remove(chapterId);
    unawaited(_window!.reload(chapterId));
  }

  // ── Window bookkeeping ──────────────────────────────────────────────────

  void _onWindowChanged() {
    _resolveHorizontalPendingJump();
    if (widget.pageMode == ReaderPageMode.horizontal) {
      _preloadWindowEdgesForHorizontal();
    }
    // Trimmed chapters release their loaded comment pages.
    _chapterComments?.retainAll(_window!.windowChapterIds);
    if (mounted) setState(() {});
  }

  void _resolveHorizontalPendingJump() {
    if (widget.pageMode != ReaderPageMode.horizontal) return;
    if (_pendingJumpParagraphId.isEmpty) return;
    if (_activeChapterId.isEmpty) return;
    // Resolving against a partially paginated chapter would land on a
    // truncated page list, and stale (pre-reflow) pages answer with the
    // wrong boundaries. Only pages stamped fresh — fully paginated for the
    // current breaker configuration — may answer a jump; otherwise kick
    // the job off and let _completePaginationJob re-run this once the
    // active chapter finishes.
    if (!_freshPages.contains(_activeChapterId)) {
      if (!_paginationJobs.containsKey(_activeChapterId)) {
        final paragraphs = _window!.paragraphsOf(_activeChapterId);
        if (paragraphs == null || paragraphs.isEmpty) return;
        _startPaginationJob(_activeChapterId, paragraphs);
      }
      return;
    }
    final pages = _pagesByChapter[_activeChapterId]!;
    if (pages.isEmpty) return;
    _activeLocalPageIndex = PageBreaker.pageForPosition(
      pages,
      _pendingJumpParagraphId,
      _pendingJumpCharOffset,
    ).clamp(0, pages.length - 1);
    _pendingJumpParagraphId = '';
    _pendingJumpCharOffset = 0;
  }

  /// Keep a couple of pages of runway at both ends of the flat list so page
  /// turns never run into a hard edge while more content exists.
  void _preloadWindowEdgesForHorizontal() {
    final window = _window!;
    final entries = _buildFlatEntries();
    if (entries.isEmpty) return;
    // Only a materialized active page can judge edge distance. Resolving
    // against loading placeholders used to fall back to index 0 on entry,
    // which read as "at both edges" and expanded the window before anything
    // was even paginated.
    final abs = _exactActiveIndex(entries);
    if (abs == null) return;
    // A boundary chapter still paginating would fake an edge: its page list
    // only grows, so its last page is provisional.
    final firstSettled = !_paginationJobs.containsKey(entries.first.chapterId);
    final lastSettled = !_paginationJobs.containsKey(entries.last.chapterId);
    if (firstSettled && abs <= 2 && window.hasChapterAbove) {
      window.expandAbove();
    }
    if (lastSettled && abs >= entries.length - 3 && window.hasChapterBelow) {
      window.expandBelow();
    }
  }

  /// The active page's flat index, or null when it is not on a materialized
  /// page (still loading, restoring, or failed). Unlike
  /// [_resolveActiveAbsoluteIndex] this never falls back.
  int? _exactActiveIndex(List<_FlatEntry> entries) {
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (entry.chapterId == _activeChapterId &&
          entry.localPageIndex == _activeLocalPageIndex &&
          !entry.loading &&
          entry.error == null) {
        return i;
      }
    }
    return null;
  }

  // ── Page computation ────────────────────────────────────────────────────

  void _ensureBreaker() {
    final size = MediaQuery.sizeOf(context);
    final pageSize = Size(
      size.width - widget.contentPadding.horizontal,
      size.height - widget.contentPadding.vertical,
    );
    final textTheme = Theme.of(context).textTheme;
    final scaler = MediaQuery.textScalerOf(context);
    final locale = Localizations.localeOf(context);
    final direction = Directionality.of(context);
    if (_breaker != null &&
        _lastPageSize == pageSize &&
        _layoutTextTheme == textTheme &&
        _layoutTextScaler == scaler &&
        _layoutLocale == locale &&
        _layoutDirection == direction) {
      return;
    }
    final reflow = _breaker != null;
    if (reflow) {
      _pagesByChapter.clear();
      _paginationJobs.clear();
      _freshPages.clear();
      _pendingJumpParagraphId = _lastReportedParagraphId;
      _pendingJumpCharOffset = _lastReportedCharOffset;
    }
    _lastPageSize = pageSize;
    _layoutTextTheme = textTheme;
    _layoutTextScaler = scaler;
    _layoutLocale = locale;
    _layoutDirection = direction;
    _breaker = _createBreaker(context);
    if (reflow) _resolveHorizontalPendingJump();
  }

  PageBreaker _createBreaker(BuildContext context) {
    final theme = Theme.of(context);
    final typo = ReaderTypography(
      textTheme: theme.textTheme,
      fontScale: widget.fontScale,
      fontFamily: widget.fontFamily,
      letterSpacing: widget.letterSpacing,
      lineHeight: widget.lineHeight,
    );
    final size = MediaQuery.sizeOf(context);
    final pageSize = Size(
      size.width - widget.contentPadding.horizontal,
      size.height - widget.contentPadding.vertical,
    );
    return PageBreaker(
      pageSize: pageSize,
      textStyle: typo.body,
      titleStyle: typo.title,
      paragraphSpacing: widget.paragraphSpacing,
      imageHeight: pageSize.width * 9 / 16,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.localeOf(context),
    );
  }

  List<PageContent> _pagesFor(String chapterId) {
    final cached = _pagesByChapter[chapterId];
    if (cached != null) return cached;
    final paragraphs = _window?.paragraphsOf(chapterId);
    if (paragraphs == null || paragraphs.isEmpty) return const [];
    final breaker = _breaker;
    if (breaker == null) return const [];
    final inFlight = _paginationJobs[chapterId];
    if (inFlight != null) return inFlight.pages;
    _startPaginationJob(chapterId, paragraphs);
    return _paginationJobs[chapterId]!.pages;
  }

  /// Lazy badge-size resolver for a chapter's paragraphs.
  ///
  /// Building a full size table up front costs one TextPainter measurement
  /// per distinct count (~17ms for a badge-dense chapter in debug) — inside
  /// the very build that starts pagination. Resolving per paragraph inside
  /// the job spreads that cost across slices, and [CommentBadge.inlineSize]'s
  /// process-wide cache keeps repeat counts free.
  Size? Function(String paragraphId) _commentBadgeSizeOf(
    String chapterId,
    List<ParagraphContent> paragraphs,
  ) {
    final badges = _layoutBadgeIdsOf?.call(chapterId) ?? const <String>{};
    final counts = <String, int>{
      for (final paragraph in paragraphs)
        if (badges.contains(paragraph.id.toStringValue()))
          paragraph.id.toStringValue(): paragraph.commentCount!,
    };
    return (paragraphId) {
      final count = counts[paragraphId];
      if (count == null) return null;
      return CommentBadge.inlineSize(context, count);
    };
  }

  void _startPaginationJob(
    String chapterId,
    List<ParagraphContent> paragraphs,
  ) {
    _paginationJobs[chapterId] = _breaker!.startPagination(
      paragraphs,
      chapterId: chapterId,
      commentBadgeSizeOf: _commentBadgeSizeOf(chapterId, paragraphs),
    );
    _schedulePaginationSlice();
  }

  /// One pagination slice per rendered frame: the slice shares the frame's
  /// time budget with build and raster, so a chapter fills in over a few
  /// dozen frames instead of freezing the first one after entry.
  void _schedulePaginationSlice() {
    if (_paginationSliceScheduled || !mounted) return;
    _paginationSliceScheduled = true;
    final scheduler = SchedulerBinding.instance;
    scheduler.scheduleFrame();
    scheduler.addPostFrameCallback((_) => _runPaginationSlice());
  }

  void _runPaginationSlice() {
    _paginationSliceScheduled = false;
    if (!mounted) return;
    // The chapter on screen always wins; queued neighbours follow in window
    // order so forward reading stays ahead of the reader.
    PaginationJob? job = _paginationJobs[_activeChapterId];
    if (job == null || job.isDone) {
      job = null;
      for (final chapterId in _window!.windowChapterIds) {
        final candidate = _paginationJobs[chapterId];
        if (candidate != null && !candidate.isDone) {
          job = candidate;
          break;
        }
      }
    }
    if (job == null) return;
    if (job.step(widget.paginationSliceBudget)) {
      _completePaginationJob(job);
    }
    setState(() {});
    if (_paginationJobs.values.any((job) => !job.isDone)) {
      _schedulePaginationSlice();
    }
  }

  void _completePaginationJob(PaginationJob job) {
    _paginationJobs.remove(job.chapterId);
    _pagesByChapter[job.chapterId] = job.result;
    _freshPages.add(job.chapterId);
    if (job.chapterId == _activeChapterId) {
      _resolveHorizontalPendingJump();
      _reissueVerticalTargetAfterPagination(job.chapterId);
    }
  }

  /// Issues a vertical scroll target (token distinguishes consecutive
  /// commands). Mid-chapter targets need a page estimate to land; while the
  /// chapter is still paginating the estimate reports unknown, so
  /// [_verticalEstimatePending] keeps the re-issue alive until an estimate
  /// answers or the reader reports an exact landing. Chapter-start targets
  /// jump to offset 0 and never need an estimate.
  void _issueVerticalTarget({
    required String chapterId,
    String paragraphId = '',
  }) {
    _verticalTarget = ReaderScrollTarget(
      token: ++_scrollToken,
      chapterId: chapterId,
      paragraphId: paragraphId,
    );
    _verticalEstimatePending = paragraphId.isNotEmpty;
  }

  /// A vertical target whose estimate was deferred (pagination was still
  /// running when it was applied) gets a fresh token now that the chapter's
  /// pages are complete; the reader applies the page estimate and
  /// fine-tunes onto the exact paragraph.
  void _reissueVerticalTargetAfterPagination(String chapterId) {
    if (widget.pageMode == ReaderPageMode.horizontal) return;
    if (!_verticalEstimatePending) return;
    final target = _verticalTarget;
    if (target == null || target.chapterId != chapterId) return;
    _issueVerticalTarget(chapterId: chapterId, paragraphId: target.paragraphId);
    setState(() {});
  }

  /// The vertical reader landed on its target exactly without needing the
  /// deferred estimate — a later job completion must not re-issue and yank
  /// the position away from the user.
  void _onVerticalTargetSettled() {
    _verticalEstimatePending = false;
  }

  /// Identity strings of the final transformed children carrying a source
  /// paragraph comment badge. Earlier children and page fragments stay clean.
  Set<String> _badgeIdsOf(String chapterId) {
    final cached = _badgeIdsByChapter[chapterId];
    if (cached != null) return cached;
    // A chapter still loading reports no paragraphs; caching that empty
    // set would hide first-load badges until a reload dropped the entry
    // (the reload command invalidates this map by hand).
    final paragraphs = _window?.paragraphsOf(chapterId);
    if (paragraphs == null || paragraphs.isEmpty) return const {};
    final seenSourceIds = <String>{};
    final badgeIds = <String>{};
    for (final paragraph in paragraphs.reversed) {
      final count = paragraph.commentCount;
      if (count == null || count <= 0) continue;
      final sourceId = paragraph.id.sourceId;
      if (sourceId == null) continue;
      if (seenSourceIds.add(sourceId)) {
        badgeIds.add(paragraph.id.toStringValue());
      }
    }
    _badgeIdsByChapter[chapterId] = badgeIds;
    return badgeIds;
  }

  double? _estimateParagraphOffset(String chapterId, String paragraphId) {
    final paragraphs = _window?.paragraphsOf(chapterId);
    if (paragraphs == null || paragraphs.isEmpty) {
      // Chapter content unavailable: the window anchors on the target
      // chapter, so offset 0 is its top (the old synchronous contract).
      return 0;
    }
    if (_breaker == null) return 0;
    if (!_freshPages.contains(chapterId)) {
      // Stale or missing pages. Never block a frame on a full-chapter
      // synchronous run (that cost 13–37 ms per slider tick on realistic
      // chapters) — kick the sliced job and report "unknown". The reader
      // holds its offset and [_completePaginationJob] re-issues the target
      // once the chapter completes.
      if (!_paginationJobs.containsKey(chapterId)) {
        _startPaginationJob(chapterId, paragraphs);
      }
      return null;
    }
    final pages = _pagesByChapter[chapterId];
    if (pages == null || pages.isEmpty) return 0;
    final idx = PageBreaker.pageForParagraph(pages, paragraphId);
    // The estimate has answered — the re-issue machinery can stand down.
    _verticalEstimatePending = false;
    if (idx <= 0) return 0;
    return idx * (_breaker?.pageSize.height ?? 0);
  }

  // ── Flat page list (horizontal) ─────────────────────────────────────────

  List<_FlatEntry> _buildFlatEntries() {
    final window = _window!;
    final entries = <_FlatEntry>[];
    for (final chapterId in window.windowChapterIds) {
      final state = window.stateOf(chapterId);
      if (state is ChapterLoaded) {
        if (state.paragraphs.isEmpty) continue;
        // Restoring into mid-chapter must not flash the chapter's first page
        // while the target page is still being computed, and a chapter with
        // no pages yet keeps one placeholder so the flat list never skips
        // over it. Both display as loading until pagination catches up. A
        // chapter with stale (pre-reflow) pages shows those instead — the
        // live typography preview reads far better than a mask, and the
        // pending-jump resolution still waits for fresh pages above.
        final masked =
            chapterId == _activeChapterId &&
            _pendingJumpParagraphId.isNotEmpty &&
            _paginationJobs.containsKey(chapterId) &&
            _pagesByChapter[chapterId] == null;
        final pages = masked ? const <PageContent>[] : _pagesFor(chapterId);
        if (masked || pages.isEmpty) {
          entries.add(
            _FlatEntry(chapterId: chapterId, localPageIndex: -1, loading: true),
          );
          continue;
        }
        for (var i = 0; i < pages.length; i++) {
          entries.add(
            _FlatEntry(chapterId: chapterId, localPageIndex: i, loading: false),
          );
        }
        // The chapter's inline comment section follows its last page; one
        // extra entry per chapter. Text pages keep their indices either way.
        if (widget.showChapterComments) {
          entries.add(
            _FlatEntry(
              chapterId: chapterId,
              localPageIndex: pages.length,
              loading: false,
              chapterEnd: true,
            ),
          );
        }
      } else if (state is ChapterLoadError) {
        entries.add(
          _FlatEntry(
            chapterId: chapterId,
            localPageIndex: -1,
            loading: false,
            error: state.error,
          ),
        );
      } else if (state is ChapterLoading) {
        entries.add(
          _FlatEntry(chapterId: chapterId, localPageIndex: -1, loading: true),
        );
      }
    }
    return entries;
  }

  int _resolveActiveAbsoluteIndex(List<_FlatEntry> entries) {
    if (entries.isEmpty) return -1;

    var sameChapterFirst = -1;
    var anchorFirst = -1;
    final anchorId = _window!.anchorChapterId;

    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (entry.chapterId == _activeChapterId &&
          entry.localPageIndex == _activeLocalPageIndex) {
        return i;
      }
      if (entry.chapterId == _activeChapterId && sameChapterFirst < 0) {
        sameChapterFirst = i;
      }
      if (entry.chapterId == anchorId && anchorFirst < 0) {
        anchorFirst = i;
      }
    }

    if (sameChapterFirst >= 0) {
      // The active position is a loading placeholder that has since
      // materialized — the reader turned into the chapter while it was
      // still fetching, so it lands on the chapter's first page. The
      // shrink-clamp below would park it on the chapter's last entry
      // instead, which with the chapter-end section on is the comments.
      if (_activeLocalPageIndex < 0) return sameChapterFirst;
      // Page count shrank (reload) — clamp to the chapter's last page.
      var last = sameChapterFirst;
      for (
        var i = sameChapterFirst + 1;
        i < entries.length && entries[i].chapterId == _activeChapterId;
        i++
      ) {
        last = i;
      }
      return last;
    }
    if (anchorFirst >= 0) return anchorFirst;
    return 0;
  }

  ReaderSlot _slotFor(_FlatEntry entry) {
    final chapterTitle = _chapterTitleOf(entry.chapterId);
    if (entry.chapterEnd) {
      return ReaderSlotChapterEnd(
        chapterId: entry.chapterId,
        chapterTitle: chapterTitle,
      );
    }
    if (entry.loading) {
      return ReaderSlotLoading(entry.chapterId, chapterTitle: chapterTitle);
    }
    if (entry.error != null) {
      return ReaderSlotError(
        chapterId: entry.chapterId,
        chapterTitle: chapterTitle,
        error: entry.error!,
      );
    }
    final pages = _pagesFor(entry.chapterId);
    final page = entry.localPageIndex < pages.length
        ? pages[entry.localPageIndex]
        : null;
    if (page == null) {
      return ReaderSlotLoading(entry.chapterId, chapterTitle: chapterTitle);
    }
    return ReaderSlotPage(page);
  }

  /// The badge lookup handed to the reading views: null disables badge
  /// rendering (reader-level switch off, or no comments plumbing).
  Set<String> Function(String chapterId)? get _badgeLookup =>
      widget.showComments && widget.onParagraphComments != null
      ? _badgeIdsOf
      : null;

  /// Badge paragraphs for pagination. Deliberately independent of
  /// [ChapterContentManager.showComments]: pages always reserve badge space
  /// while comment plumbing exists, so toggling badge visibility never
  /// re-pages the book — text, page breaks and the restored position stay
  /// identical, only the capsules appear or disappear.
  Set<String> Function(String chapterId)? get _layoutBadgeIdsOf =>
      widget.onParagraphComments != null ? _badgeIdsOf : null;

  String? _chapterTitleOf(String chapterId) {
    for (final chapter in widget.chapters) {
      if (chapter.id == chapterId) return chapter.title;
    }
    return null;
  }

  /// Builds a chapter's inline end-of-chapter comment section, or null while
  /// the reader-level switch is off. Both reading views call it once per
  /// loaded chapter; the controller cache keeps pages alive across the
  /// section's mount/unmount cycles.
  Widget? _buildChapterEnd(String chapterId) {
    if (!widget.showChapterComments) return null;
    final comments = _chapterComments ??= ChapterCommentsCache(
      service: widget.feedService,
      feedId: widget.feedId,
      bookId: widget.bookId,
    );
    final section = ChapterEndComments(
      service: widget.feedService,
      feedId: widget.feedId,
      bookId: widget.bookId,
      chapterId: chapterId,
      controller: comments[chapterId],
      scrollable: widget.pageMode == ReaderPageMode.horizontal,
    );
    if (widget.pageMode == ReaderPageMode.horizontal) {
      // The horizontal slot already applies the full content padding.
      return section;
    }
    // Vertical mode pads each paragraph row itself; match its side insets.
    return Padding(
      padding: EdgeInsets.only(
        left: widget.contentPadding.left,
        right: widget.contentPadding.right,
      ),
      child: section,
    );
  }

  // ── Page turns (horizontal) ─────────────────────────────────────────────

  void _applyActiveEntry(_FlatEntry entry) {
    _activeChapterId = entry.chapterId;
    _activeLocalPageIndex = entry.localPageIndex;
    _pendingJumpParagraphId = '';
  }

  void _onHorizontalNextPage() {
    final entries = _buildFlatEntries();
    final abs = _resolveActiveAbsoluteIndex(entries);
    if (abs < 0) return;
    if (abs < entries.length - 1) {
      _applyActiveEntry(entries[abs + 1]);
      _reportCurrentHorizontalPosition();
    }
    _preloadWindowEdgesForHorizontal();
    _window!.maintainAround(_activeChapterId);
    setState(() {});
  }

  void _onHorizontalPrevPage() {
    final entries = _buildFlatEntries();
    final abs = _resolveActiveAbsoluteIndex(entries);
    if (abs < 0) return;
    if (abs > 0) {
      _applyActiveEntry(entries[abs - 1]);
      _reportCurrentHorizontalPosition();
    }
    _preloadWindowEdgesForHorizontal();
    _window!.maintainAround(_activeChapterId);
    setState(() {});
  }

  void _reportCurrentHorizontalPosition() {
    var paragraphId = '';
    var charOffset = 0;
    if (_activeLocalPageIndex >= 0) {
      final pages = _pagesFor(_activeChapterId);
      if (_activeLocalPageIndex < pages.length) {
        final page = pages[_activeLocalPageIndex];
        paragraphId = page.firstParagraphId;
        charOffset = page.firstCharOffset;
      } else if (pages.isNotEmpty) {
        // The chapter-end comments entry: anchor progress on the chapter's
        // last text page so a restore lands right before the section.
        final page = pages.last;
        paragraphId = page.firstParagraphId;
        charOffset = page.firstCharOffset;
      }
    }
    _reportPosition(_activeChapterId, paragraphId, 0, charOffset);
    if (paragraphId.isNotEmpty &&
        _paginationJobs.containsKey(_activeChapterId)) {
      // A re-pagination is in flight; the pending-jump landing should
      // follow the page the user is actually reading now, not the one they
      // were on when the typography change committed.
      _pendingJumpParagraphId = paragraphId;
      _pendingJumpCharOffset = charOffset;
    }
  }

  // ── Position reporting ──────────────────────────────────────────────────

  void _reportPosition(
    String chapterId,
    String paragraphId,
    double offset, [
    int charOffset = 0,
  ]) {
    _lastReportedChapterId = chapterId;
    _lastReportedParagraphId = paragraphId;
    _lastReportedCharOffset = charOffset;
    widget.controller.reportPosition(
      chapterId: chapterId,
      paragraphId: paragraphId,
      paragraphOffset: offset,
      charOffset: charOffset,
    );
    // Vertical scrolls report positions without rebuilding this manager,
    // so the publish cannot wait for the next build there.
    _schedulePageProgressPublish();
  }

  // ── Page progress publishing ────────────────────────────────────────────

  /// Publishes page progress after the frame that changed it.
  ///
  /// Every mutation that can move the active page (turns, jumps, pagination
  /// slices, window changes, re-flows) ends in a rebuild of this manager, so
  /// scheduling from [build] covers them all with one deduplicated callback.
  /// Position reports schedule it too, because vertical scrolling moves the
  /// progress without rebuilding this widget. Publishing post-frame keeps
  /// the parent's ValueNotifier — and whatever listens to it — out of this
  /// widget's build phase.
  void _schedulePageProgressPublish() {
    if (_pageProgressPublishScheduled || !mounted) return;
    _pageProgressPublishScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _pageProgressPublishScheduled = false;
      if (!mounted) return;
      _publishPageProgress();
    });
  }

  void _publishPageProgress() {
    final notifier = widget.pageProgress;
    if (notifier == null) return;
    final progress = _computePageProgress();
    if (notifier.value != progress) notifier.value = progress;
  }

  ReaderChapterProgress? _computePageProgress() {
    if (widget.pageMode != ReaderPageMode.horizontal) {
      return _computeVerticalProgress();
    }
    final chapterId = _activeChapterId;
    if (chapterId.isEmpty) return null;
    // A pending jump means the target page is not resolved yet (or the
    // chapter is still masked behind a loading placeholder).
    if (_pendingJumpParagraphId.isNotEmpty) return null;
    // Provisional while the job runs: the page count only grows, which is
    // fine for a status label; the final value lands on completion.
    final pages =
        _paginationJobs[chapterId]?.pages ?? _pagesByChapter[chapterId];
    if (pages == null || pages.isEmpty) return null;
    return ReaderChapterProgress(
      chapterId: chapterId,
      unitIndex: _activeLocalPageIndex.clamp(0, pages.length - 1),
      unitCount: pages.length,
    );
  }

  /// Vertical mode has no pages: the paragraph-granular position feeds the
  /// same whole-book percentage the bookshelf computes, so the two surfaces
  /// agree on one reading position.
  ReaderChapterProgress? _computeVerticalProgress() {
    final chapterId = _lastReportedChapterId.isNotEmpty
        ? _lastReportedChapterId
        : _activeChapterId;
    final paragraphId = _lastReportedParagraphId;
    if (chapterId.isEmpty || paragraphId.isEmpty) return null;
    final paragraphs = _window?.paragraphsOf(chapterId);
    if (paragraphs == null || paragraphs.isEmpty) return null;
    var index = -1;
    for (var i = 0; i < paragraphs.length; i++) {
      if (paragraphs[i].id.toStringValue() == paragraphId) {
        index = i;
        break;
      }
    }
    if (index < 0) return null;
    return ReaderChapterProgress(
      chapterId: chapterId,
      unitIndex: index,
      unitCount: paragraphs.length,
      unit: ReaderProgressUnit.paragraph,
    );
  }

  // ── Widget updates ──────────────────────────────────────────────────────

  @override
  void didUpdateWidget(covariant ChapterContentManager oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerCommand);
      widget.controller.addListener(_onControllerCommand);
    }

    final sourceChanged =
        oldWidget.feedId != widget.feedId ||
        oldWidget.bookId != widget.bookId ||
        oldWidget.chapters != widget.chapters;

    if (sourceChanged) {
      final sameBook =
          oldWidget.feedId == widget.feedId &&
          oldWidget.bookId == widget.bookId;
      final anchorId =
          _activeChapterId.isNotEmpty &&
              widget.chapters.any((c) => c.id == _activeChapterId)
          ? _activeChapterId
          : (widget.chapters.isNotEmpty ? widget.chapters.first.id : '');
      _pagesByChapter.clear();
      _badgeIdsByChapter.clear();
      _paginationJobs.clear();
      _freshPages.clear();
      if (!sameBook) _chapterComments?.clear();
      _activeChapterId = anchorId;
      _activeLocalPageIndex = 0;
      if (sameBook && anchorId == _lastReportedChapterId) {
        _pendingJumpParagraphId = _lastReportedParagraphId;
        _pendingJumpCharOffset = _lastReportedCharOffset;
      }
      _window!.setChapters(widget.chapters, anchorId);
      _issueVerticalTarget(chapterId: anchorId);
      setState(() {});
      return;
    }

    if (oldWidget.transformerRevision != widget.transformerRevision) {
      // Paragraphs must be re-fetched through the new transformer combination.
      _pagesByChapter.clear();
      _badgeIdsByChapter.clear();
      _paginationJobs.clear();
      _freshPages.clear();
      _window!.reloadWindow();
      _restorePositionAfterReflow();
      return;
    }

    // showComments is intentionally absent here: badge visibility never
    // changes pagination (see [_layoutBadgeIdsOf]), so flipping the switch
    // leaves every page and the restored position untouched.
    final typographyChanged =
        oldWidget.fontScale != widget.fontScale ||
        oldWidget.fontFamily != widget.fontFamily ||
        oldWidget.letterSpacing != widget.letterSpacing ||
        oldWidget.paragraphSpacing != widget.paragraphSpacing ||
        oldWidget.lineHeight != widget.lineHeight ||
        (oldWidget.onParagraphComments == null) !=
            (widget.onParagraphComments == null);

    if (typographyChanged) {
      // Pages are stale but paragraphs are not. Keep them displayed while
      // fresh ones paginate — masking on every live-commit during a slider
      // drag would flash loading slots at throttle rate — but drop their
      // freshness stamp so restores only trust fully re-paginated chapters.
      // Horizontal mode re-runs the window's jobs right away (on-screen
      // chapter first); vertical mode paginates lazily when the restore
      // estimate asks.
      _paginationJobs.clear();
      _freshPages.clear();
      _breaker = null;
      _lastPageSize = Size.zero;
      if (widget.pageMode == ReaderPageMode.horizontal) {
        _ensureBreaker();
        for (final chapterId in _window!.windowChapterIds) {
          final paragraphs = _window!.paragraphsOf(chapterId);
          if (paragraphs != null && paragraphs.isNotEmpty) {
            _startPaginationJob(chapterId, paragraphs);
          }
        }
      }
      if (widget.prewarmCustomFont) {
        for (final chapterId in _window!.windowChapterIds) {
          final paragraphs = _window!.paragraphsOf(chapterId);
          if (paragraphs != null) {
            _scheduleGlyphWarmup(chapterId, paragraphs);
          }
        }
      }
      _restorePositionAfterReflow();
      return;
    }

    if (oldWidget.pageMode != widget.pageMode) {
      _switchMode(oldWidget.pageMode, widget.pageMode);
    }
  }

  /// Re-resolve the saved position after content re-flowed (settings or
  /// conversion change).
  void _restorePositionAfterReflow() {
    final chapterId = _lastReportedChapterId.isNotEmpty
        ? _lastReportedChapterId
        : _activeChapterId;
    final paragraphId = _lastReportedParagraphId;
    final charOffset = _lastReportedCharOffset;
    _activeChapterId = chapterId;
    _pendingJumpParagraphId = paragraphId;
    _pendingJumpCharOffset = charOffset;
    _issueVerticalTarget(chapterId: chapterId, paragraphId: paragraphId);
    _ensureBreaker();
    _resolveHorizontalPendingJump();
    setState(() {});
  }

  void _switchMode(ReaderPageMode oldMode, ReaderPageMode newMode) {
    final chapterId = _lastReportedChapterId.isNotEmpty
        ? _lastReportedChapterId
        : _activeChapterId;
    _activeChapterId = chapterId;

    // If the window drifted away from the position (possible after long
    // vertical runs), re-anchor around it.
    if (!_window!.windowChapterIds.contains(chapterId)) {
      _window!.jumpTo(chapterId);
    }

    if (newMode == ReaderPageMode.vertical) {
      _issueVerticalTarget(
        chapterId: chapterId,
        paragraphId: _lastReportedParagraphId,
      );
    } else {
      // Switching into paged mode: the last reported char offset anchors the
      // target page (0 when coming from vertical mode, which does not track
      // character positions).
      _pendingJumpParagraphId = _lastReportedParagraphId;
      _pendingJumpCharOffset = _lastReportedCharOffset;
      _ensureBreaker();
      _resolveHorizontalPendingJump();
    }
    setState(() {});
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final window = _window;
    if (window == null || widget.chapters.isEmpty) {
      return const SizedBox.shrink();
    }

    _schedulePageProgressPublish();

    if (widget.pageMode == ReaderPageMode.vertical) {
      // The vertical reader renders paragraphs directly, but its restore
      // estimates read pages — the breaker must exist for the async
      // estimate + re-issue flow to work at all (and the badge warmup in
      // initState expects it by its post-frame callback).
      _ensureBreaker();
      return SeamlessVerticalReader(
        key: _verticalReaderKey,
        window: window,
        chapters: widget.chapters,
        contentPadding: widget.contentPadding,
        viewportTopInset: widget.viewportTopInset,
        viewportBottomInset: widget.viewportBottomInset,
        fontScale: widget.fontScale,
        fontFamily: widget.fontFamily,
        letterSpacing: widget.letterSpacing,
        paragraphSpacing: widget.paragraphSpacing,
        lineHeight: widget.lineHeight,
        onPositionChanged: _reportPosition,
        onToggleControls: widget.onToggleControls,
        onPageTurnStart: widget.onPageTurnStart,
        onParagraphLongPress: widget.onParagraphLongPress,
        selectedChapterId: widget.selectedChapterId,
        selectedParagraphId: widget.selectedParagraphId,
        scrollTarget: _verticalTarget,
        estimateParagraphOffset: _estimateParagraphOffset,
        onTargetSettled: _onVerticalTargetSettled,
        commentBadgeIdsOf: _badgeLookup,
        onParagraphComments: widget.onParagraphComments,
        chapterEndBuilder: widget.showChapterComments ? _buildChapterEnd : null,
      );
    }

    _ensureBreaker();
    final entries = _buildFlatEntries();
    if (entries.isEmpty) {
      return const LoadingState();
    }

    final abs = _resolveActiveAbsoluteIndex(entries);
    final current = _slotFor(entries[abs]);
    final prev = abs > 0 ? _slotFor(entries[abs - 1]) : null;
    final next = abs < entries.length - 1 ? _slotFor(entries[abs + 1]) : null;

    return HorizontalReaderView(
      currentSlot: current,
      prevSlot: prev,
      nextSlot: next,
      isFirstPage: abs == 0 && !window.hasChapterAbove,
      isLastPage: abs == entries.length - 1 && !window.hasChapterBelow,
      fontScale: widget.fontScale,
      fontFamily: widget.fontFamily,
      letterSpacing: widget.letterSpacing,
      paragraphSpacing: widget.paragraphSpacing,
      lineHeight: widget.lineHeight,
      contentPadding: widget.contentPadding,
      onNextPage: _onHorizontalNextPage,
      onPrevPage: _onHorizontalPrevPage,
      onToggleControls: widget.onToggleControls,
      onPageTurnStart: widget.onPageTurnStart,
      onRetryChapter: (chapterId) => window.retry(chapterId),
      onRefreshBook: widget.onRefreshBook,
      onParagraphLongPress: widget.onParagraphLongPress,
      commentBadgeIdsOf: _badgeLookup,
      onParagraphComments: widget.onParagraphComments,
      chapterEndBuilder: widget.showChapterComments ? _buildChapterEnd : null,
      selectedChapterId: widget.selectedChapterId,
      selectedParagraphId: widget.selectedParagraphId,
    );
  }
}

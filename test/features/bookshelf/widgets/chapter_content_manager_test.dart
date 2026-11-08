import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:langhuan/features/bookshelf/comments/chapter_end_comments.dart';
import 'package:langhuan/features/bookshelf/reader_settings_provider.dart'
    show ReaderPageMode;
import 'package:langhuan/features/bookshelf/widgets/chapter_content_manager.dart';
import 'package:langhuan/features/bookshelf/widgets/comment_badge.dart';
import 'package:langhuan/features/bookshelf/widgets/horizontal_reader_view.dart'
    show ReaderSlotLoading;
import 'package:langhuan/features/bookshelf/widgets/reader_controller.dart';
import 'package:langhuan/features/bookshelf/widgets/reader_types.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/src/rust/api/comments.dart';
import 'package:langhuan/src/rust/api/types.dart';
import 'package:langhuan/l10n/app_localizations.dart';

import '../../feeds/fake_feed_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const chapters = [
    ChapterInfoModel(id: 'c1', title: 'Chapter One'),
    ChapterInfoModel(id: 'c2', title: 'Chapter Two'),
  ];

  final data = <String, List<ParagraphContent>>{
    'c1': [
      ParagraphContent_Title(
        id: ParagraphId(original: OriginalParagraphId.source('t1'), path: []),
        text: 'Chapter One',
      ),
      ParagraphContent_Text(
        id: ParagraphId(original: OriginalParagraphId.source('p1'), path: []),
        content: 'Body one.',
      ),
    ],
    'c2': [
      ParagraphContent_Title(
        id: ParagraphId(original: OriginalParagraphId.source('t2'), path: []),
        text: 'Chapter Two',
      ),
      ParagraphContent_Text(
        id: ParagraphId(original: OriginalParagraphId.source('p2'), path: []),
        content: 'Body two.',
      ),
    ],
  };

  /// Service that serves [data] and records every paragraphs() call.
  FakeFeedService service({
    required List<(String, String, String, bool)> calls,
    bool Function(String chapterId)? failFor,
  }) {
    return FakeFeedService(
      paragraphsHandler:
          (feedId, bookId, chapterId, {forceRefresh = false}) async {
            calls.add((feedId, bookId, chapterId, forceRefresh));
            if (failFor?.call(chapterId) ?? false) {
              throw StateError('boom');
            }
            return data[chapterId] ?? const [];
          },
    );
  }

  /// Pumps the manager with the given [service]; returns the reader
  /// controller after settling, with positions recorded into [positions].
  Future<ReaderController> pumpManager(
    WidgetTester tester, {
    required FakeFeedService service,
    ReaderPageMode pageMode = ReaderPageMode.horizontal,
    String transformerRevision = '',
    List<ReaderPosition>? positions,
    Future<void> Function()? onRefreshBook,
    void Function(String, ParagraphContent)? onParagraphComments,
  }) async {
    final controller = ReaderController();
    controller.onPositionChanged = positions?.add;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ChapterContentManager(
            feedService: service,
            feedId: 'f1',
            bookId: 'b1',
            chapters: chapters,
            controller: controller,
            pageMode: pageMode,
            onToggleControls: () {},
            onRefreshBook: onRefreshBook,
            onParagraphComments: onParagraphComments,
            fontScale: 1.0,
            lineHeight: 1.5,
            contentPadding: const EdgeInsets.all(16),
            transformerRevision: transformerRevision,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    return controller;
  }

  for (final mode in ReaderPageMode.values) {
    testWidgets('only the last transformed child gets a badge in $mode', (
      tester,
    ) async {
      await pumpManager(
        tester,
        pageMode: mode,
        service: FakeFeedService(
          paragraphsHandler:
              (feedId, bookId, chapterId, {forceRefresh = false}) async => [
                for (var i = 0; i < 2; i++)
                  ParagraphContent.text(
                    id: ParagraphId(
                      original: OriginalParagraphId.source(chapterId),
                      path: [ParagraphPathIndex(index: i)],
                    ),
                    content: '$chapterId child $i',
                    commentCount: 12,
                  ),
              ],
        ),
        onParagraphComments: (_, _) {},
      );
      final texts = tester
          .widgetList<BadgedText>(find.byType(BadgedText))
          .toList();
      expect(texts.where((t) => t.commentCount != null), isNotEmpty);
      for (final text in texts) {
        expect(text.commentCount, text.text.endsWith('child 1') ? 12 : null);
      }
    });
  }

  for (final mode in ReaderPageMode.values) {
    testWidgets(
      'narration visibility distinguishes transformed siblings in $mode',
      (tester) async {
        ParagraphId id(int index) => ParagraphId(
          original: const OriginalParagraphId.source('shared'),
          path: [ParagraphPathIndex(index: index)],
        );
        final reader = await pumpManager(
          tester,
          pageMode: mode,
          service: FakeFeedService(
            paragraphsHandler: (f, b, c, {forceRefresh = false}) async => [
              for (var i = 0; i < 40; i++)
                ParagraphContent.text(
                  id: id(i),
                  content: 'Transformed paragraph $i. ' * 4,
                ),
            ],
          ),
        );
        expect(reader.isParagraphVisible!('c1', id(0).toStringValue()), isTrue);
        expect(
          reader.isParagraphVisible!('c1', id(39).toStringValue()),
          isFalse,
        );
        reader.jumpTo(chapterId: 'c1', paragraphId: id(39).toStringValue());
        await tester.pumpAndSettle();
        expect(
          reader.isParagraphVisible!('c1', id(39).toStringValue()),
          isTrue,
        );
      },
    );

    testWidgets('narration visibility tracks the displayed chapter in $mode', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final reader = await pumpManager(
        tester,
        pageMode: mode,
        service: service(calls: []),
      );
      final first = data['c1']![1].id.toStringValue();
      final second = data['c2']![1].id.toStringValue();
      expect(reader.isParagraphVisible!('c1', first), isTrue);
      expect(reader.isParagraphVisible!('c2', first), isFalse);
      reader.jumpTo(chapterId: 'c2', paragraphId: second);
      await tester.pumpAndSettle();
      expect(reader.isParagraphVisible!('c2', second), isTrue);
      reader.cancelPendingNavigation();
      expect(reader.pendingChapterId, isNull);
      await tester.pumpWidget(const SizedBox());
      expect(reader.isParagraphVisible, isNull);
      expect(reader.onCancelPendingNavigation, isNull);
      semantics.dispose();
    });
  }

  testWidgets('loads the anchor chapter through the injected service', (
    tester,
  ) async {
    final calls = <(String, String, String, bool)>[];
    await pumpManager(
      tester,
      service: service(calls: calls),
      positions: [],
    );

    // The anchor chapter is fetched (with its neighbor) and rendered.
    expect(find.text('Chapter One'), findsOneWidget);
    expect(calls.where((c) => c.$3 == 'c1' && c.$4 == false), isNotEmpty);
  });

  testWidgets(
    'last page turns into an end page, refreshes, and returns without changing progress',
    (tester) async {
      final positions = <ReaderPosition>[];
      var refreshes = 0;
      await pumpManager(
        tester,
        service: service(calls: []),
        positions: positions,
        onRefreshBook: () async {
          refreshes++;
        },
      );
      await tester.tapAt(const Offset(700, 300));
      await tester.pumpAndSettle();
      final saved = positions.last;
      final reports = positions.length;
      await tester.tapAt(const Offset(700, 300));
      await tester.pumpAndSettle();
      expect(find.text("You're all caught up").hitTestable(), findsOneWidget);
      expect(positions.length, reports);
      expect(positions.last, same(saved));
      await tester.tap(
        find.byKey(const ValueKey('reader-end-refresh')).hitTestable(),
      );
      await tester.pumpAndSettle();
      expect(refreshes, 1);
      await tester.tapAt(const Offset(700, 300));
      await tester.pumpAndSettle();
      expect(find.text("You're all caught up").hitTestable(), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('reader-end-return')).hitTestable(),
      );
      await tester.pumpAndSettle();
      expect(find.text('Body two.').hitTestable(), findsOneWidget);
      expect(positions.length, reports);
    },
  );

  testWidgets('a jump command switches chapters and reports the position', (
    tester,
  ) async {
    final positions = <ReaderPosition>[];
    final controller = await pumpManager(
      tester,
      service: service(calls: []),
      positions: positions,
    );

    controller.jumpTo(chapterId: 'c2');
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    expect(find.text('Chapter Two'), findsOneWidget);
    expect(positions, isNotEmpty);
    expect(positions.last.chapterId, 'c2');
  });

  testWidgets('tapping the right edge turns to the next chapter page', (
    tester,
  ) async {
    final positions = <ReaderPosition>[];
    await pumpManager(
      tester,
      service: service(calls: []),
      positions: positions,
    );

    // Horizontal mode only reports positions on jumps and page turns, so an
    // empty log before the tap proves the report below comes from the turn.
    expect(positions, isEmpty);

    // Each chapter fits one page, so the flat list is [c1 page 0, c2 page 0].
    await tester.tapAt(const Offset(760, 300));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    // The 3-page strip keeps both chapters built, so tree presence cannot
    // distinguish pages — the reported position is the contract.
    expect(positions, hasLength(1));
    expect(positions.single.chapterId, 'c2');
    expect(positions.single.paragraphId, isNotEmpty);
  });

  testWidgets('a reload command re-fetches the chapter from the warmed cache', (
    tester,
  ) async {
    final calls = <(String, String, String, bool)>[];
    final controller = await pumpManager(
      tester,
      service: service(calls: calls),
    );

    final before = calls.where((c) => c.$3 == 'c1').length;
    expect(before, 1);

    controller.requestChapterReload('c1');
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    // Re-fetched, but not with forceRefresh: the pull-refresh already warmed
    // the backend cache before issuing the reload command.
    expect(calls.where((c) => c.$3 == 'c1').length, 2);
    expect(
      calls.where((c) => c.$3 == 'c1').map((c) => c.$4),
      everyElement(false),
    );
    expect(find.text('Chapter One'), findsOneWidget);
  });

  testWidgets('a transformer chain change re-fetches the window paragraphs', (
    tester,
  ) async {
    final calls = <(String, String, String, bool)>[];
    final fake = service(calls: calls);
    await pumpManager(tester, service: fake);

    final before = calls.where((c) => c.$3 == 'c1').length;
    expect(before, 1);

    // A changed effective chain must reprocess cached source paragraphs.
    await pumpManager(
      tester,
      service: fake,
      transformerRevision: 'updated-chain',
    );

    expect(calls.where((c) => c.$3 == 'c1').length, 2);
    expect(find.text('Chapter One'), findsOneWidget);
  });

  testWidgets('vertical mode renders the window chapters seamlessly', (
    tester,
  ) async {
    await pumpManager(
      tester,
      service: service(calls: []),
      pageMode: ReaderPageMode.vertical,
    );

    expect(find.text('Chapter One'), findsOneWidget);
    expect(find.text('Body one.'), findsOneWidget);
    expect(find.text('Chapter Two'), findsOneWidget);
  });

  testWidgets('a failed chapter shows its error and recovers on retry', (
    tester,
  ) async {
    final calls = <(String, String, String, bool)>[];
    var failing = true;
    final fake = service(
      calls: calls,
      failFor: (chapterId) => failing && chapterId == 'c1',
    );

    await pumpManager(tester, service: fake);

    // The anchor's error surfaces with a retry affordance.
    expect(find.textContaining('boom'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    failing = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    expect(find.text('Chapter One'), findsOneWidget);
    expect(find.textContaining('boom'), findsNothing);
  });

  // A chapter long enough to span several pages at the default test
  // surface, with a unique-source badged paragraph per entry.
  List<ParagraphContent> pagedBodyOf(String chapterId) => [
    for (var i = 0; i < 60; i++)
      ParagraphContent.text(
        id: ParagraphId(
          original: OriginalParagraphId.source('$chapterId-p$i'),
          path: const [],
        ),
        content: '$chapterId paragraph $i',
        commentCount: 12,
      ),
  ];

  /// Controller shared by successive [pumpWithSettings] calls of one test,
  /// so rebuilding with different settings updates the same manager state.
  ReaderController? sharedController;

  tearDown(() {
    sharedController?.dispose();
    sharedController = null;
  });

  /// Pumps the manager with configurable showComments and a page-progress
  /// notifier; each call rebuilds the SAME state with new settings.
  Future<void> pumpWithSettings(
    WidgetTester tester, {
    required FakeFeedService fake,
    required ValueNotifier<ReaderChapterProgress?> pageProgress,
    required bool showComments,
    ReaderPageMode pageMode = ReaderPageMode.horizontal,
    double fontScale = 1.0,
    bool showChapterComments = false,
    bool settle = true,
  }) async {
    final controller = sharedController ??= ReaderController();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ChapterContentManager(
            feedService: fake,
            feedId: 'f1',
            bookId: 'b1',
            chapters: chapters,
            controller: controller,
            pageMode: pageMode,
            onToggleControls: () {},
            onParagraphComments: (_, _) {},
            fontScale: fontScale,
            lineHeight: 1.5,
            contentPadding: const EdgeInsets.all(16),
            transformerRevision: '',
            showComments: showComments,
            showChapterComments: showChapterComments,
            pageProgress: pageProgress,
          ),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
    }
  }

  testWidgets('page progress tracks page turns and chapter jumps', (
    tester,
  ) async {
    final pageProgress = ValueNotifier<ReaderChapterProgress?>(null);
    addTearDown(pageProgress.dispose);
    final fake = FakeFeedService(
      paragraphsHandler:
          (feedId, bookId, chapterId, {forceRefresh = false}) async =>
              pagedBodyOf(chapterId),
    );

    await pumpWithSettings(
      tester,
      fake: fake,
      pageProgress: pageProgress,
      showComments: true,
    );

    final initial = pageProgress.value;
    expect(initial, isNotNull, reason: 'the active chapter paginated');
    expect(initial!.chapterId, 'c1');
    expect(initial.unitIndex, 0);
    expect(initial.unitCount, greaterThan(1), reason: 'multi-page chapter');

    // Turn within the chapter: the index advances, the count holds.
    await tester.tapAt(const Offset(760, 300));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    final turned = pageProgress.value;
    expect(turned, isNotNull);
    expect(turned!.chapterId, 'c1');
    expect(turned.unitIndex, 1);
    expect(turned.unitCount, initial.unitCount);

    // A jump to another chapter resets to that chapter's resolved page.
    sharedController!.jumpTo(chapterId: 'c2');
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    final jumped = pageProgress.value;
    expect(jumped, isNotNull);
    expect(jumped!.chapterId, 'c2');
    expect(jumped.unitIndex, 0);
    expect(jumped.unitCount, greaterThan(1));
  });

  testWidgets('vertical mode publishes paragraph-granular progress', (
    tester,
  ) async {
    final pageProgress = ValueNotifier<ReaderChapterProgress?>(null);
    addTearDown(pageProgress.dispose);
    final fake = FakeFeedService(
      paragraphsHandler:
          (feedId, bookId, chapterId, {forceRefresh = false}) async =>
              pagedBodyOf(chapterId),
    );

    await pumpWithSettings(
      tester,
      fake: fake,
      pageProgress: pageProgress,
      showComments: true,
      pageMode: ReaderPageMode.vertical,
    );

    // Scrolling reports the first visible paragraph, and that report feeds
    // the progress notifier — paragraph units, not pages.
    await tester.dragFrom(const Offset(400, 300), const Offset(0, -300));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    final progress = pageProgress.value;
    expect(progress, isNotNull, reason: 'scrolling published progress');
    expect(progress!.chapterId, 'c1');
    expect(progress.unit, ReaderProgressUnit.paragraph);
    expect(progress.unitCount, 60, reason: 'title-free body paragraph count');
    expect(progress.unitIndex, greaterThan(0));
  });

  testWidgets('toggling showComments keeps pages and position intact', (
    tester,
  ) async {
    final calls = <(String, String, String, bool)>[];
    final pageProgress = ValueNotifier<ReaderChapterProgress?>(null);
    addTearDown(pageProgress.dispose);
    final fake = FakeFeedService(
      paragraphsHandler:
          (feedId, bookId, chapterId, {forceRefresh = false}) async {
            calls.add((feedId, bookId, chapterId, forceRefresh));
            return pagedBodyOf(chapterId);
          },
    );

    await pumpWithSettings(
      tester,
      fake: fake,
      pageProgress: pageProgress,
      showComments: true,
    );

    await tester.tapAt(const Offset(760, 300));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    final withBadges = pageProgress.value;
    expect(withBadges, isNotNull);
    expect(withBadges!.unitIndex, greaterThan(0));
    final fetchesBefore = calls.length;
    expect(
      tester
          .widgetList<BadgedText>(find.byType(BadgedText))
          .where((t) => t.commentCount != null),
      isNotEmpty,
      reason: 'badges render while comments are shown',
    );

    // Same state, comments hidden — only the badge capsules may change.
    await pumpWithSettings(
      tester,
      fake: fake,
      pageProgress: pageProgress,
      showComments: false,
    );

    expect(calls.length, fetchesBefore, reason: 'no chapter re-fetched');
    expect(
      pageProgress.value,
      withBadges,
      reason: 'page breaks and active page must be untouched',
    );
    expect(
      tester
          .widgetList<BadgedText>(find.byType(BadgedText))
          .where((t) => t.commentCount != null),
      isEmpty,
      reason: 'badges stopped rendering',
    );
  });

  group('chapter-end comments', () {
    /// One comment page per chapter, keyed so assertions can address a
    /// single chapter's section.
    CommentPage commentPageOf(String chapterId) => CommentPage(
      items: [
        CommentItem(
          id: '$chapterId-k1',
          author: CommentAuthor(name: 'Reader'),
          text: 'Comment for $chapterId',
          replies: const CommentReplies(totalCount: 1),
        ),
      ],
      nextCursorJson: null,
    );

    FakeFeedService commentsService() => FakeFeedService(
      paragraphsHandler:
          (feedId, bookId, chapterId, {forceRefresh = false}) async =>
              data[chapterId] ?? const [],
      openCommentsPageHandler:
          ({
            required String feedId,
            required String bookId,
            required String chapterId,
            String? paragraphId,
            String? parentId,
            String? cursorJson,
          }) async => commentPageOf(chapterId),
    );

    testWidgets(
      'horizontal: the section follows the chapter pages and the switch',
      (tester) async {
        final pageProgress = ValueNotifier<ReaderChapterProgress?>(null);
        addTearDown(pageProgress.dispose);
        final fake = commentsService();
        final positions = <ReaderPosition>[];

        await pumpWithSettings(
          tester,
          fake: fake,
          pageProgress: pageProgress,
          showComments: true,
          showChapterComments: true,
        );
        sharedController!.onPositionChanged = positions.add;

        // Chapter one fits on one page, so its section is the next slot.
        expect(find.byType(ChapterEndComments), findsOneWidget);
        expect(find.text('Comment for c1'), findsOneWidget);

        // Turning onto the section anchors progress on the chapter's last
        // text page, so a restore lands before the comments.
        await tester.tapAt(const Offset(760, 300));
        await tester.pumpAndSettle(const Duration(milliseconds: 50));
        expect(pageProgress.value, isNotNull);
        expect(pageProgress.value!.chapterId, 'c1');
        expect(positions.last.chapterId, 'c1');
        expect(positions.last.paragraphId, isNotEmpty);

        // Hiding the section never re-pages the text.
        final withSection = pageProgress.value;
        await pumpWithSettings(
          tester,
          fake: fake,
          pageProgress: pageProgress,
          showComments: true,
          showChapterComments: false,
        );
        expect(find.byType(ChapterEndComments), findsNothing);
        expect(pageProgress.value?.unitCount, withSection?.unitCount);

        // Showing it again reuses the cached controller's loaded page.
        await pumpWithSettings(
          tester,
          fake: fake,
          pageProgress: pageProgress,
          showComments: true,
          showChapterComments: true,
        );
        expect(find.byType(ChapterEndComments), findsOneWidget);
        expect(find.text('Comment for c1'), findsOneWidget);
      },
    );

    testWidgets('vertical: the section flows after the chapter paragraphs', (
      tester,
    ) async {
      final pageProgress = ValueNotifier<ReaderChapterProgress?>(null);
      addTearDown(pageProgress.dispose);

      await pumpWithSettings(
        tester,
        fake: commentsService(),
        pageProgress: pageProgress,
        showComments: true,
        showChapterComments: true,
        pageMode: ReaderPageMode.vertical,
      );

      expect(find.byType(ChapterEndComments), findsWidgets);
      expect(find.text('Comment for c1'), findsOneWidget);
    });
  });

  group('live typography reflow', () {
    /// Saved positions report [ParagraphId.toStringValue]; jumps must use
    /// the same form to match paginated items.
    final p30Id = ParagraphId(
      original: const OriginalParagraphId.source('c1-p30'),
      path: const [],
    ).toStringValue();

    /// Badge-free multi-page body: badged paragraphs render through
    /// [BadgedText]'s rich-span path, which plain text finders cannot
    /// match, so the reflow assertions below use clean [Text] widgets.
    List<ParagraphContent> plainBodyOf(String chapterId) => [
      for (var i = 0; i < 60; i++)
        ParagraphContent.text(
          id: ParagraphId(
            original: OriginalParagraphId.source('$chapterId-p$i'),
            path: const [],
          ),
          content: '$chapterId paragraph $i',
        ),
    ];

    testWidgets(
      'horizontal: a font change keeps the page on screen, then restores the position',
      (tester) async {
        final pageProgress = ValueNotifier<ReaderChapterProgress?>(null);
        addTearDown(pageProgress.dispose);
        final fake = FakeFeedService(
          paragraphsHandler:
              (feedId, bookId, chapterId, {forceRefresh = false}) async =>
                  plainBodyOf(chapterId),
        );

        await pumpWithSettings(
          tester,
          fake: fake,
          pageProgress: pageProgress,
          showComments: true,
        );

        // Land mid-chapter so the reflow has a real position to restore.
        sharedController!.jumpTo(chapterId: 'c1', paragraphId: p30Id);
        await tester.pumpAndSettle(const Duration(milliseconds: 50));
        expect(find.text('c1 paragraph 30').hitTestable(), findsOneWidget);

        // Commit bigger type like a live slider commit would. One frame in,
        // the chapter is still re-paginating: the stale page stays on
        // screen (its paragraphs reflowed at the new size) instead of a
        // loading mask flashing over the reader.
        await pumpWithSettings(
          tester,
          fake: fake,
          pageProgress: pageProgress,
          showComments: true,
          fontScale: 1.6,
          settle: false,
        );
        expect(find.byType(ReaderSlotLoading), findsNothing);
        expect(find.text('c1 paragraph 30'), findsOneWidget);

        // Once the fresh pages land, the position is restored onto the
        // same paragraph.
        await tester.pumpAndSettle(const Duration(milliseconds: 50));
        expect(find.text('c1 paragraph 30').hitTestable(), findsOneWidget);
      },
    );

    testWidgets(
      'vertical: a font change holds the offset, then re-lands on the paragraph',
      (tester) async {
        final pageProgress = ValueNotifier<ReaderChapterProgress?>(null);
        addTearDown(pageProgress.dispose);
        final fake = FakeFeedService(
          paragraphsHandler:
              (feedId, bookId, chapterId, {forceRefresh = false}) async =>
                  plainBodyOf(chapterId),
        );

        await pumpWithSettings(
          tester,
          fake: fake,
          pageProgress: pageProgress,
          showComments: true,
          pageMode: ReaderPageMode.vertical,
        );

        // Jump deep; the async estimate plus the re-issue after pagination
        // must land on the paragraph (never rely on the 16-viewport walk
        // alone).
        sharedController!.jumpTo(chapterId: 'c1', paragraphId: p30Id);
        await tester.pumpAndSettle(const Duration(milliseconds: 50));
        final scrollable = tester.state<ScrollableState>(
          find.byType(Scrollable),
        );
        final landed = scrollable.position.pixels;
        expect(landed, greaterThan(500));
        expect(find.text('c1 paragraph 30').hitTestable(), findsOneWidget);

        // Commit bigger type. The first reflow frame holds the current
        // offset — the estimate is pending while pagination runs, and
        // jumping to the chapter top would be disorienting.
        await pumpWithSettings(
          tester,
          fake: fake,
          pageProgress: pageProgress,
          showComments: true,
          pageMode: ReaderPageMode.vertical,
          fontScale: 1.6,
          settle: false,
        );
        expect(
          scrollable.position.pixels,
          greaterThan(500),
          reason: 'offset held while the estimate is pending',
        );

        // Pagination completes, the target is re-issued with an estimate,
        // and the fine-tune lands on the paragraph again.
        await tester.pumpAndSettle(const Duration(milliseconds: 50));
        expect(find.text('c1 paragraph 30').hitTestable(), findsOneWidget);
        expect(scrollable.position.pixels, greaterThan(500));
      },
    );
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:langhuan/features/bookshelf/reader_settings_provider.dart'
    show ReaderPageMode;
import 'package:langhuan/features/bookshelf/widgets/chapter_content_manager.dart';
import 'package:langhuan/features/bookshelf/widgets/reader_controller.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
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
      ParagraphContent_Title(id: ParagraphId.id('t1'), text: 'Chapter One'),
      ParagraphContent_Text(id: ParagraphId.id('p1'), content: 'Body one.'),
    ],
    'c2': [
      ParagraphContent_Title(id: ParagraphId.id('t2'), text: 'Chapter Two'),
      ParagraphContent_Text(id: ParagraphId.id('p2'), content: 'Body two.'),
    ],
  };

  /// Service that serves [data] and records every paragraphs() call.
  FakeFeedService service({
    required List<(String, String, String, bool)> calls,
    bool Function(String chapterId)? failFor,
  }) {
    return FakeFeedService(
      paragraphsHandler: (feedId, bookId, chapterId, {forceRefresh = false}) {
        calls.add((feedId, bookId, chapterId, forceRefresh));
        if (failFor?.call(chapterId) ?? false) {
          return Stream.error(StateError('boom'));
        }
        return Stream.fromIterable(data[chapterId] ?? const []);
      },
    );
  }

  /// Pumps the manager with the given [service]; returns the reader
  /// controller after settling, with positions recorded into [positions].
  Future<ReaderController> pumpManager(
    WidgetTester tester, {
    required FakeFeedService service,
    ReaderPageMode pageMode = ReaderPageMode.horizontal,
    ChineseConversionMode conversion = ChineseConversionMode.none,
    List<ReaderPosition>? positions,
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
            fontScale: 1.0,
            lineHeight: 1.5,
            contentPadding: const EdgeInsets.all(16),
            chineseConversion: conversion,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    return controller;
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
    expect(
      calls.where((c) => c.$3 == 'c1' && c.$4 == false),
      isNotEmpty,
    );
  });

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

  testWidgets('a conversion change re-fetches the window paragraphs', (
    tester,
  ) async {
    final calls = <(String, String, String, bool)>[];
    final fake = service(calls: calls);
    await pumpManager(tester, service: fake);

    final before = calls.where((c) => c.$3 == 'c1').length;
    expect(before, 1);

    // Rebuild with a different conversion mode: paragraphs must be fetched
    // again through the new conversion.
    await pumpManager(
      tester,
      service: fake,
      conversion: ChineseConversionMode.s2T,
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
}

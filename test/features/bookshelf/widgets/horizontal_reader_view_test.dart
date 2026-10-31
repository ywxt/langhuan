import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:langhuan/features/bookshelf/widgets/horizontal_reader_view.dart';
import 'package:langhuan/features/bookshelf/widgets/page_breaker.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import 'package:langhuan/src/rust/api/types.dart';

PageContent _page(String id, String text, {String chapterId = 'c1'}) {
  return PageContent(
    chapterId: chapterId,
    items: [
      PageItem(
        source: ParagraphContent_Text(id: ParagraphId.id(id), content: text),
        paragraphIndex: 0,
        paragraphId: id,
      ),
    ],
  );
}

Widget _host({
  ReaderSlot? current,
  ReaderSlot? prev,
  ReaderSlot? next,
  bool isFirst = false,
  bool isLast = false,
  VoidCallback? onNext,
  VoidCallback? onPrev,
  VoidCallback? onToggle,
  VoidCallback? onPageTurnStart,
  void Function(String chapterId)? onRetryChapter,
  void Function(
    String chapterId,
    String paragraphId,
    ParagraphContent paragraph,
    Rect rect,
  )?
  onParagraphLongPress,
}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SizedBox.expand(
        child: HorizontalReaderView(
          currentSlot: current ?? ReaderSlotPage(_page('p1', 'page one')),
          prevSlot: prev,
          nextSlot: next,
          isFirstPage: isFirst,
          isLastPage: isLast,
          fontScale: 1,
          lineHeight: 1.8,
          contentPadding: EdgeInsets.zero,
          onNextPage: onNext ?? () {},
          onPrevPage: onPrev ?? () {},
          onToggleControls: onToggle ?? () {},
          onPageTurnStart: onPageTurnStart,
          onRetryChapter: onRetryChapter,
          onParagraphLongPress: onParagraphLongPress,
        ),
      ),
    ),
  );
}

double _stripOffset(WidgetTester tester) => tester
    .widget<Transform>(
      find.byKey(const ValueKey('horizontal-reader-page-strip')),
    )
    .transform
    .storage[12];

void main() {
  testWidgets('system brightness updates pixels of the retained current page', (
    tester,
  ) async {
    final key = GlobalKey();
    final page = _page('stable', 'retained page');
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData.light().copyWith(
          scaffoldBackgroundColor: Colors.white,
        ),
        darkTheme: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: Colors.black,
        ),
        home: Scaffold(
          body: RepaintBoundary(
            key: key,
            child: HorizontalReaderView(
              currentSlot: ReaderSlotPage(page),
              isFirstPage: true,
              isLastPage: true,
              fontScale: 1,
              lineHeight: 1.8,
              contentPadding: EdgeInsets.zero,
              onNextPage: () {},
              onPrevPage: () {},
              onToggleControls: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Future<int> background() async {
      final image =
          await (key.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage();
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final offset = ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
      final red = data.getUint8(offset);
      image.dispose();
      return red;
    }

    expect(await tester.runAsync(background), 255);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(await tester.runAsync(background), 0);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(await tester.runAsync(background), 255);
  });

  testWidgets('renders the current page text', (tester) async {
    await tester.pumpWidget(
      _host(current: ReaderSlotPage(_page('p1', 'page one'))),
    );

    expect(find.text('page one'), findsOneWidget);
  });

  group('tap zones', () {
    testWidgets('right third turns to the next page', (tester) async {
      var nextCalls = 0;
      await tester.pumpWidget(
        _host(
          current: ReaderSlotPage(_page('p1', 'page one')),
          next: ReaderSlotPage(_page('p2', 'page two')),
          onNext: () => nextCalls++,
        ),
      );

      await tester.tapAt(const Offset(600, 300));
      await tester.pumpAndSettle();

      expect(nextCalls, 1);
    });

    testWidgets('right third dismisses paragraph actions immediately', (
      tester,
    ) async {
      var dismissed = false;
      var dismissedBeforeTurn = false;
      await tester.pumpWidget(
        _host(
          next: ReaderSlotPage(_page('p2', 'page two')),
          onPageTurnStart: () => dismissed = true,
          onNext: () => dismissedBeforeTurn = dismissed,
        ),
      );

      await tester.tapAt(const Offset(600, 300));
      await tester.pumpAndSettle();

      expect(dismissed, isTrue);
      expect(dismissedBeforeTurn, isTrue);
    });

    testWidgets('left third turns to the previous page', (tester) async {
      var prevCalls = 0;
      await tester.pumpWidget(
        _host(
          current: ReaderSlotPage(_page('p2', 'page two')),
          prev: ReaderSlotPage(_page('p1', 'page one')),
          onPrev: () => prevCalls++,
        ),
      );

      await tester.tapAt(const Offset(100, 300));
      await tester.pumpAndSettle();

      expect(prevCalls, 1);
    });

    testWidgets('middle third toggles the controls', (tester) async {
      var toggles = 0;
      await tester.pumpWidget(
        _host(
          current: ReaderSlotPage(_page('p1', 'page one')),
          onToggle: () {
            toggles++;
          },
        ),
      );

      await tester.tapAt(const Offset(350, 300));
      await tester.pump();

      expect(toggles, 1);
    });

    testWidgets('left tap on the first page does nothing', (tester) async {
      var prevCalls = 0;
      await tester.pumpWidget(
        _host(
          current: ReaderSlotPage(_page('p1', 'page one')),
          isFirst: true,
          onPrev: () => prevCalls++,
        ),
      );

      await tester.tapAt(const Offset(100, 300));
      await tester.pump();

      expect(prevCalls, 0);
    });

    testWidgets('right tap on the last page does nothing', (tester) async {
      var nextCalls = 0;
      await tester.pumpWidget(
        _host(
          current: ReaderSlotPage(_page('p1', 'page one')),
          isLast: true,
          onNext: () => nextCalls++,
        ),
      );

      await tester.tapAt(const Offset(600, 300));
      await tester.pump();

      expect(nextCalls, 0);
    });
  });

  group('swipe', () {
    testWidgets('held drag preserves small movements and immediate reversals', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 3.5;
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _host(
          prev: ReaderSlotPage(_page('previous', 'previous page')),
          next: ReaderSlotPage(_page('next', 'next page')),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(HorizontalReaderView)),
      );
      await gesture.moveBy(const Offset(-60, 0));
      await tester.pump();
      final start = _stripOffset(tester);
      for (var i = 0; i < 100; i++) {
        await gesture.moveBy(const Offset(-0.1, 0));
        await tester.pump(const Duration(milliseconds: 4));
      }
      expect(_stripOffset(tester), closeTo(start - 10, 0.01));
      final paintedOrigin = tester.getTopLeft(find.text('page one')) * 3.5;
      expect(paintedOrigin.dx, closeTo(paintedOrigin.dx.roundToDouble(), 1e-6));
      await tester.pump(const Duration(milliseconds: 80));
      expect(_stripOffset(tester), closeTo(start - 10, 0.01));
      for (final delta in [80.0, -120.0, 50.0]) {
        final before = _stripOffset(tester);
        await gesture.moveBy(Offset(delta, 0));
        await tester.pump(const Duration(milliseconds: 4));
        expect(_stripOffset(tester), closeTo(before + delta, 0.01));
      }
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(_stripOffset(tester), 0);
    });

    testWidgets('touch down holds settling immediately and tap resumes it', (
      tester,
    ) async {
      var turns = 0;
      await tester.pumpWidget(
        _host(
          next: ReaderSlotPage(_page('next', 'next page')),
          onNext: () => turns++,
        ),
      );
      await tester.tapAt(const Offset(600, 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final contactOffset = _stripOffset(tester);
      expect(contactOffset, lessThan(0));

      final gesture = await tester.startGesture(const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 80));
      expect(_stripOffset(tester), contactOffset);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(turns, 1);
    });

    testWidgets('snapshots retained text pages for the turn animation', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          current: ReaderSlotPage(_page('p2', 'current page')),
          prev: ReaderSlotPage(_page('p1', 'previous page')),
          next: ReaderSlotPage(_page('p3', 'next page')),
        ),
      );

      final snapshots = tester.widgetList<SnapshotWidget>(
        find.byType(SnapshotWidget),
      );
      expect(snapshots, hasLength(3));
      expect(
        snapshots.map((widget) => widget.controller).toSet(),
        hasLength(1),
      );
      expect(snapshots.first.controller.allowSnapshotting, isTrue);
    });

    testWidgets('settle animation translates a retained page strip', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          current: ReaderSlotPage(_page('p1', 'page one')),
          next: ReaderSlotPage(_page('p2', 'page two')),
        ),
      );

      await tester.tapAt(const Offset(600, 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      final transform = tester.widget<Transform>(
        find.byKey(const ValueKey('horizontal-reader-page-strip')),
      );
      expect(transform.transform.storage[12], lessThan(0));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('horizontal-reader-page-strip')),
          matching: find.byType(RepaintBoundary),
        ),
        findsNWidgets(3),
      );
      expect(find.byType(SnapshotWidget), findsNWidgets(2));
    });

    testWidgets('drag left past the threshold settles onto next', (
      tester,
    ) async {
      var nextCalls = 0;
      await tester.pumpWidget(
        _host(
          current: ReaderSlotPage(_page('p1', 'page one')),
          next: ReaderSlotPage(_page('p2', 'page two')),
          onNext: () => nextCalls++,
        ),
      );

      await tester.drag(
        find.byType(HorizontalReaderView),
        const Offset(-300, 0),
      );
      await tester.pumpAndSettle();

      expect(nextCalls, 1);
    });

    testWidgets('drag right past the threshold settles onto prev', (
      tester,
    ) async {
      var prevCalls = 0;
      await tester.pumpWidget(
        _host(
          current: ReaderSlotPage(_page('p2', 'page two')),
          prev: ReaderSlotPage(_page('p1', 'page one')),
          onPrev: () => prevCalls++,
        ),
      );

      await tester.drag(
        find.byType(HorizontalReaderView),
        const Offset(300, 0),
      );
      await tester.pumpAndSettle();

      expect(prevCalls, 1);
    });

    testWidgets('drag cannot cross the first page boundary', (tester) async {
      var prevCalls = 0;
      await tester.pumpWidget(
        _host(
          current: ReaderSlotPage(_page('p1', 'page one')),
          isFirst: true,
          onPrev: () => prevCalls++,
        ),
      );

      await tester.drag(
        find.byType(HorizontalReaderView),
        const Offset(300, 0),
      );
      await tester.pumpAndSettle();

      expect(prevCalls, 0);
    });
  });

  group('slots', () {
    testWidgets('loading slot shows a spinner', (tester) async {
      await tester.pumpWidget(
        _host(
          current: ReaderSlotPage(_page('p1', 'page one')),
          next: const ReaderSlotLoading('c2'),
        ),
      );

      // The next slot is off-screen; drag part-way to reveal it.
      await tester.drag(
        find.byType(HorizontalReaderView),
        const Offset(-150, 0),
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('error slot shows the retry button', (tester) async {
      final retryChapters = <String>[];
      await tester.pumpWidget(
        _host(
          current: ReaderSlotPage(_page('p1', 'page one')),
          next: const ReaderSlotError(chapterId: 'c2', error: 'boom'),
          onRetryChapter: retryChapters.add,
        ),
      );

      await tester.drag(
        find.byType(HorizontalReaderView),
        const Offset(-150, 0),
      );
      await tester.pump();

      expect(find.text('boom'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('dragging past the last page shows the end-of-book mark', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(current: ReaderSlotPage(_page('p1', 'page one')), isLast: true),
      );

      await tester.drag(
        find.byType(HorizontalReaderView),
        const Offset(-150, 0),
      );
      await tester.pump();

      expect(find.text("You've reached the end of the book"), findsOneWidget);
    });
  });

  group('paragraph selection', () {
    testWidgets(
      'long-press reports the pressed paragraph rect, not the whole page',
      (tester) async {
        Rect? reported;
        String? reportedParagraphId;
        await tester.pumpWidget(
          _host(
            current: ReaderSlotPage(
              PageContent(
                chapterId: 'c1',
                items: [
                  PageItem(
                    source: ParagraphContent_Text(
                      id: const ParagraphId.id('a'),
                      content: 'first paragraph line',
                    ),
                    paragraphIndex: 0,
                    paragraphId: 'a',
                  ),
                  PageItem(
                    source: ParagraphContent_Text(
                      id: const ParagraphId.id('b'),
                      content: 'second paragraph line',
                    ),
                    paragraphIndex: 1,
                    paragraphId: 'b',
                  ),
                  PageItem(
                    source: ParagraphContent_Text(
                      id: const ParagraphId.id('c'),
                      content: 'third paragraph line',
                    ),
                    paragraphIndex: 2,
                    paragraphId: 'c',
                  ),
                ],
              ),
            ),
            onParagraphLongPress: (chapterId, paragraphId, paragraph, rect) {
              reported = rect;
              reportedParagraphId = paragraphId;
            },
          ),
        );

        final secondRect = tester.getRect(find.text('second paragraph line'));
        await tester.longPressAt(secondRect.center);
        await tester.pump();

        expect(reportedParagraphId, 'b');
        expect(reported, isNotNull);
        expect(reported!.top, closeTo(secondRect.top, 1));
        expect(reported!.height, closeTo(secondRect.height, 1));
      },
    );
  });
}

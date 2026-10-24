import 'package:flutter/material.dart';
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
          onRetryChapter: onRetryChapter,
          onParagraphLongPress: onParagraphLongPress,
        ),
      ),
    ),
  );
}

void main() {
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
      await tester.pump();

      expect(nextCalls, 1);
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
      await tester.pump();

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
          next: const ReaderSlotError(chapterId: 'c2', message: 'boom'),
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

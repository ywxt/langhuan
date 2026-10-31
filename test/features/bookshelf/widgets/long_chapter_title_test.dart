import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/widgets/page_breaker.dart';
import 'package:langhuan/features/bookshelf/widgets/page_content_view.dart';
import 'package:langhuan/features/bookshelf/widgets/reader_top_bar.dart';
import 'package:langhuan/src/rust/api/types.dart';

void main() {
  testWidgets('an oversized title spans pages without lost text or overflow', (
    tester,
  ) async {
    final theme = ThemeData(
      textTheme: const TextTheme(
        headlineSmall: TextStyle(fontSize: 24, height: 1.3, fontFamily: 'Ahem'),
      ),
    );
    final title = List.filled(40, 'A lengthy chapter title ').join();
    final breaker = PageBreaker(
      pageSize: const Size(220, 180),
      textStyle: const TextStyle(fontSize: 16, height: 1.8),
      titleStyle: theme.textTheme.headlineSmall!,
      paragraphSpacing: 16,
      imageHeight: 100,
      textDirection: TextDirection.ltr,
    );
    final pages = breaker.computePages([
      ParagraphContent.title(
        id: const ParagraphId(
          original: OriginalParagraphId.source('title'),
          path: [],
        ),
        text: title,
      ),
    ], chapterId: 'chapter');
    expect(pages.length, greaterThan(1));
    expect(
      pages.expand((p) => p.items).map((i) => i.visibleText).join(),
      title,
    );
    for (final page in pages) {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 220,
                height: 180,
                child: PageContentView(page: page),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    }
    final last = pages.last;
    expect(
      PageBreaker.pageForPosition(
        pages,
        last.firstParagraphId,
        last.firstCharOffset,
      ),
      pages.length - 1,
    );
  });

  testWidgets('toolbar title stays on one line and exposes the full text', (
    tester,
  ) async {
    final title = List.filled(20, 'Long chapter title').join(' ');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: ReaderTopBar(
              topPadding: 0,
              chapterTitle: title,
              backgroundColor: Colors.white,
              titleTextStyle: const TextStyle(fontSize: 18),
              bookmarksTooltip: 'Bookmarks',
              refreshTooltip: 'Refresh',
              isRefreshing: false,
              onBack: () {},
              onOpenBookmarks: () {},
              onRefresh: () {},
            ),
          ),
        ),
      ),
    );
    expect(tester.widget<Text>(find.text(title)).maxLines, 1);
    expect(find.byTooltip(title), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:langhuan/features/bookshelf/widgets/horizontal_reader_view.dart';
import 'package:langhuan/features/bookshelf/widgets/page_breaker.dart';
import 'package:langhuan/src/rust/api/types.dart';

PageContent _page(String id, String text) {
  return PageContent(
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
  required PageContent current,
  PageContent? prev,
  PageContent? next,
  required VoidCallback onNext,
  required VoidCallback onPrev,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox.expand(
        child: HorizontalReaderView(
          currentPage: current,
          prevPage: prev,
          nextPage: next,
          isFirstPage: prev == null,
          isLastPage: next == null,
          fontScale: 1,
          lineHeight: 1.8,
          contentPadding: EdgeInsets.zero,
          onNextPage: onNext,
          onPrevPage: onPrev,
          centerChapterId: 'c1',
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('swipe left requests next page', (tester) async {
    var nextCalls = 0;
    var prevCalls = 0;

    await tester.pumpWidget(
      _host(
        current: _page('p1', 'current'),
        next: _page('p2', 'next'),
        onNext: () => nextCalls++,
        onPrev: () => prevCalls++,
      ),
    );

    final target = find.byType(HorizontalReaderView);
    await tester.drag(target, const Offset(-350, 0));
    await tester.pumpAndSettle();

    expect(nextCalls, 1);
    expect(prevCalls, 0);
  });

  testWidgets('swipe right requests previous page', (tester) async {
    var nextCalls = 0;
    var prevCalls = 0;

    await tester.pumpWidget(
      _host(
        current: _page('p2', 'current'),
        prev: _page('p1', 'prev'),
        next: _page('p3', 'next'),
        onNext: () => nextCalls++,
        onPrev: () => prevCalls++,
      ),
    );

    final target = find.byType(HorizontalReaderView);
    await tester.drag(target, const Offset(350, 0));
    await tester.pumpAndSettle();

    expect(prevCalls, 1);
    expect(nextCalls, 0);
  });

  testWidgets('rebuild after settle keeps swipe behavior stable', (
    tester,
  ) async {
    var nextCalls = 0;

    await tester.pumpWidget(
      _host(
        current: _page('p1', 'current'),
        next: _page('p2', 'next'),
        onNext: () => nextCalls++,
        onPrev: () {},
      ),
    );

    final target = find.byType(HorizontalReaderView);
    await tester.drag(target, const Offset(-350, 0));
    await tester.pumpAndSettle();
    expect(nextCalls, 1);

    await tester.pumpWidget(
      _host(
        current: _page('p2', 'new current'),
        next: _page('p3', 'next'),
        prev: _page('p1', 'prev'),
        onNext: () => nextCalls++,
        onPrev: () {},
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(target, const Offset(-350, 0));
    await tester.pumpAndSettle();
    expect(nextCalls, 2);
  });
}

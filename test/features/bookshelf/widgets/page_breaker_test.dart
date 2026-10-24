import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:langhuan/features/bookshelf/widgets/page_breaker.dart';
import 'package:langhuan/src/rust/api/types.dart';

void main() {
  test('preserves chapter id on every page when a paragraph spans pages', () {
    final breaker = PageBreaker(
      pageSize: const Size(240, 120),
      textStyle: const TextStyle(fontSize: 18, height: 1.5),
      titleStyle: const TextStyle(fontSize: 24),
      paragraphSpacing: 12,
      imageHeight: 100,
      textDirection: TextDirection.ltr,
    );
    final pages = breaker.computePages([
      ParagraphContent_Text(
        id: const ParagraphId.id('p1'),
        content: List.filled(80, 'long paragraph').join(' '),
      ),
    ], chapterId: 'chapter-42');

    expect(pages.length, greaterThan(1));
    expect(pages.every((page) => page.chapterId == 'chapter-42'), isTrue);
  });

  test('pageForPosition restores the exact continuation page', () {
    // Paragraph p1 spans three pages (offsets 0 / 240 / 480); p2 and p3 are
    // short and share page 3, where only p2 leads.
    PageItem item(String id, int? start) => PageItem(
          source: ParagraphContent_Text(
            id: ParagraphId.id(id),
            content: 'x',
          ),
          paragraphIndex: 0,
          paragraphId: id,
          startOffset: start,
          endOffset: start == null ? null : start + 240,
        );
    final pages = [
      PageContent(items: [item('p1', null)]), // p1 start (offset 0)
      PageContent(items: [item('p1', 240)]), // p1 continuation
      PageContent(items: [item('p1', 480)]), // p1 continuation
      PageContent(items: [item('p2', null), item('p3', null)]),
    ];

    // Tier 1 — exact first-item match on a continuation page.
    expect(PageBreaker.pageForPosition(pages, 'p1', 240), 1);
    expect(PageBreaker.pageForPosition(pages, 'p1', 480), 2);
    // Paragraph start also matches exactly.
    expect(PageBreaker.pageForPosition(pages, 'p1', 0), 0);
    expect(PageBreaker.pageForPosition(pages, 'p2', 0), 3);

    // Tier 2 — stale offset (e.g. font size changed): fall back to the
    // first page whose leading paragraph matches.
    expect(PageBreaker.pageForPosition(pages, 'p1', 999), 0);

    // Tier 3 — paragraph only appears mid-page: use the containing page.
    expect(PageBreaker.pageForPosition(pages, 'p3', 0), 3);

    // Unknown paragraph: last page, like pageForParagraph.
    expect(PageBreaker.pageForPosition(pages, 'px', 0), 3);
  });
}

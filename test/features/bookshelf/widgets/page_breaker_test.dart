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
}

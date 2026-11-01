import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:langhuan/features/bookshelf/widgets/page_breaker.dart';
import 'package:langhuan/features/feeds/feed_service.dart'
    show ParagraphIdStringExt;
import 'package:langhuan/src/rust/api/types.dart';

void main() {
  ParagraphId pid(String s) =>
      ParagraphId(original: OriginalParagraphId.source(s), path: const []);

  // A deterministic, badge-dense chapter: titles, images, paragraphs long
  // enough to split across pages, and ~70% carrying badges — the shape that
  // made whole-chapter pagination expensive enough to need chunking.
  List<ParagraphContent> chapter() => [
    for (var i = 0; i < 40; i++)
      switch (i % 10) {
        0 => ParagraphContent.title(
          id: pid('t$i'),
          text: '第${i + 1}章 標題',
        ),
        3 => ParagraphContent.image(
          id: pid('g$i'),
          url: 'https://example.invalid/x.png',
        ),
        _ => ParagraphContent.text(
          id: pid('p$i'),
          content: i % 3 == 0
              ? List.filled(40 + i, '文').join()
              : List.filled(4 + i % 7, '字').join(),
          commentCount: i % 10 < 7 ? 2 + i : null,
        ),
      },
  ];

  Map<String, Size> badgeSizesFor(List<ParagraphContent> items) => {
    for (final item in items)
      if ((item.commentCount ?? 0) > 0)
        item.id.toStringValue(): const Size(42, 18),
  };

  String describe(List<PageContent> pages) => pages
      .map(
        (page) =>
            '${page.chapterId}: '
            '${page.items.map((item) {
              final tail = item.endOffset == null ? '' : '..${item.endOffset}';
              final tracking = item.letterSpacing == null
                  ? ''
                  : '(ls=${item.letterSpacing})';
              final gap = item.badgeGap == null ? '' : '(gap=${item.badgeGap})';
              return '${item.paragraphId}#${item.paragraphIndex}'
                  '@${item.startOffset ?? 0}$tail$tracking$gap';
            }).join(' | ')}',
      )
      .join('\n');

  PageBreaker breakerFor(Size pageSize, TextDirection direction) =>
      PageBreaker(
        pageSize: pageSize,
        textStyle: const TextStyle(fontSize: 16, height: 1.5),
        titleStyle: const TextStyle(fontSize: 24),
        paragraphSpacing: 12,
        imageHeight: 100,
        textDirection: direction,
      );

  test('stepped pagination matches the synchronous result exactly', () {
    const sizes = [Size(300, 400), Size(240, 120), Size(380, 700)];
    const budgets = [
      Duration.zero, // the finest possible granularity: one paragraph per step
      Duration(milliseconds: 1),
      Duration(seconds: 10), // everything in one step
    ];
    for (final size in sizes) {
      for (final direction in TextDirection.values) {
        final breaker = breakerFor(size, direction);
        for (final withBadges in [false, true]) {
          final items = chapter();
          final badgeSizes =
              withBadges ? badgeSizesFor(items) : const <String, Size>{};
          final sync = breaker.computePages(
            items,
            chapterId: 'ch',
            commentBadgeSizes: badgeSizes,
          );
          final job = breaker.startPagination(
            items,
            chapterId: 'ch',
            commentBadgeSizes: badgeSizes,
          );
          var steps = 0;
          while (!job.step(budgets[steps % budgets.length])) {
            steps++;
          }
          expect(job.isDone, isTrue, reason: 'size=$size');
          expect(
            describe(job.result),
            describe(sync),
            reason:
                'size=${size.width}x${size.height} '
                'direction=$direction badges=$withBadges',
          );
        }
      }
    }
  });

  test('a zero budget processes exactly one paragraph per step', () {
    final breaker = breakerFor(const Size(240, 120), TextDirection.ltr);
    final items = chapter();
    final job = breaker.startPagination(
      items,
      chapterId: 'ch',
      commentBadgeSizes: badgeSizesFor(items),
    );
    var steps = 0;
    while (!job.step(Duration.zero)) {
      steps++;
    }
    // One paragraph per step, one final step to flush the trailing page.
    expect(steps, items.length);
    expect(job.isDone, isTrue);
  });

  test('pages are append-only while a job runs', () {
    final breaker = breakerFor(const Size(240, 120), TextDirection.ltr);
    final items = chapter();
    final job = breaker.startPagination(
      items,
      chapterId: 'ch',
      commentBadgeSizes: badgeSizesFor(items),
    );
    final snapshots = <List<PageContent>>[];
    while (!job.step(Duration.zero)) {
      snapshots.add(List.of(job.pages));
    }
    expect(snapshots, isNotEmpty);
    for (var i = 0; i < snapshots.length; i++) {
      final previous = i == 0 ? const <PageContent>[] : snapshots[i - 1];
      final current = snapshots[i];
      // Every earlier page survives byte-for-byte; growth only appends.
      expect(current.length, greaterThanOrEqualTo(previous.length));
      for (var k = 0; k < previous.length; k++) {
        expect(identical(current[k], previous[k]), isTrue, reason: 'page $k');
      }
    }
    expect(describe(job.result), describe(job.pages));
  });

  test('degenerate geometry emits the single all-items page', () {
    for (final size in [const Size(0, 100), const Size(200, 0)]) {
      final breaker = breakerFor(size, TextDirection.ltr);
      final job = breaker.startPagination(
        chapter(),
        chapterId: 'ch',
        commentBadgeSizes: const {},
      );
      expect(job.step(const Duration(milliseconds: 4)), isTrue);
      expect(job.pages, hasLength(1));
      expect(job.pages.single.items, hasLength(40));
    }
  });

  test('empty input completes with no pages', () {
    final breaker = breakerFor(const Size(300, 400), TextDirection.ltr);
    final job = breaker.startPagination(const [], chapterId: 'ch');
    expect(job.step(const Duration(milliseconds: 4)), isTrue);
    expect(job.result, isEmpty);
    expect(job.step(const Duration(milliseconds: 4)), isTrue); // idempotent
  });
}

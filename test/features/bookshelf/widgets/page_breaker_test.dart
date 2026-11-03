import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:langhuan/features/bookshelf/widgets/page_breaker.dart';
import 'package:langhuan/features/feeds/feed_service.dart'
    show ParagraphIdStringExt;
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
        id: const ParagraphId(
          original: OriginalParagraphId.source('p1'),
          path: [],
        ),
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
        id: ParagraphId(original: OriginalParagraphId.source(id), path: []),
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

  group('linear pagination matches the substring-layout algorithm', () {
    // The line-metrics rewrite of PageBreaker._layoutText must be
    // observationally identical to the quadratic original it replaced:
    // same pages, same items, same (startOffset, endOffset) splits. The
    // original lives on below as _ReferencePageBreaker, frozen verbatim
    // from the pre-rewrite implementation.
    final rng = math.Random(20261030);

    const cjkPool = '的一是不了人我在有他这中大来上国说时要们为到以会家而后能';
    const gappyWordPool = 'lorem  ipsum dolor  sit amet  ';
    const arabicText = 'مرحبا بالعالم هذا نص تجريبي طويل لاختبار الاتجاه';

    String run(String pool, int n) =>
        List.generate(n, (_) => pool[rng.nextInt(pool.length)]).join();

    // Whitespace-free content: exact parity with the reference. Without
    // spaces or newlines a line can never end in a hung trailing cluster,
    // so every split lands exactly on a line boundary and the substring
    // version's re-layout agreed with the full layout's line grid. The
    // one-character entries cannot split at all.
    final cleanTextCases = <String>[
      '',
      ' ',
      '\n',
      'a',
      '一',
      '短句。这是一个短句。',
      run(cjkPool, 2000),
      '今天天气真好🌞🌞nice👍👍👍再来一段中文确保换行发生🀄🀄',
    ];

    // Anything with spaces or newlines: a split can land before a line's
    // hung trailing whitespace (the caret query stops short of trailing
    // spaces and newlines), and the substring version then re-wrapped the
    // remainder as a fresh paragraph — shifting every later line boundary
    // and under-filling the rest of the paragraph's pages (with newlines
    // it even gave a lone empty line a page of its own). The rewrite keeps
    // the paragraph's own line grid instead (pages fill to their true
    // capacity), which is the intentional behaviour change: for these
    // cases we assert the coverage invariants, not parity.
    final messyTextCases = <String>[
      '    ${run(cjkPool, 300)}',
      'Words wrapped at spaces with plenty of soft breaks.',
      '中文english混合文本 with words 数字1234567890 标点，。！？；：、（）《》',
      'line one\nline two\n\nline four',
      run(gappyWordPool, 300),
      arabicText,
      '${run(cjkPool, 300)}      ',
      '${run(cjkPool, 300)}${' ' * 200}',
      ' ' * 500,
    ];

    String describePages(List<PageContent> pages) => pages
        .map(
          (p) =>
              '${p.chapterId}: '
              '${p.items.map((i) => '${i.paragraphId}#${i.paragraphIndex}'
                  '@${i.startOffset ?? 0}..${i.endOffset ?? -1}').join(' | ')}',
        )
        .join('\n');

    String describeScenario(
      Size pageSize,
      TextStyle style,
      double spacing,
      String label,
    ) =>
        'size=${pageSize.width}x${pageSize.height} '
        'style=$style spacing=$spacing case=$label';

    void checkParity({
      required Size pageSize,
      required TextStyle textStyle,
      required double paragraphSpacing,
      double imageHeight = 100,
      TextDirection textDirection = TextDirection.ltr,
      required List<ParagraphContent> items,
      required String label,
    }) {
      final actual = PageBreaker(
        pageSize: pageSize,
        textStyle: textStyle,
        titleStyle: const TextStyle(fontSize: 24),
        paragraphSpacing: paragraphSpacing,
        imageHeight: imageHeight,
        textDirection: textDirection,
      ).computePages(items, chapterId: 'ch');

      final oversizedTitle =
          pageSize.width > 0 &&
          pageSize.height > 4 &&
          items.any((item) {
            if (item is! ParagraphContent_Title) return false;
            final painter = TextPainter(
              text: TextSpan(
                text: item.text,
                style: const TextStyle(fontSize: 24),
              ),
              textDirection: textDirection,
            )..layout(maxWidth: pageSize.width);
            final oversized = painter.height > pageSize.height - 4;
            painter.dispose();
            return oversized;
          });
      if (oversizedTitle) {
        // The baseline clipped headings taller than a page. The new behaviour
        // intentionally changes page boundaries; verify complete text coverage.
        for (var index = 0; index < items.length; index++) {
          final original = switch (items[index]) {
            ParagraphContent_Text(:final content) => content,
            ParagraphContent_Title(:final text) => text,
            _ => null,
          };
          if (original == null) continue;
          expect(
            actual
                .expand((p) => p.items)
                .where((item) => item.paragraphIndex == index)
                .map((item) => item.visibleText)
                .join(),
            original,
          );
        }
        return;
      }

      final expected = _ReferencePageBreaker(
        pageSize: pageSize,
        textStyle: textStyle,
        titleStyle: const TextStyle(fontSize: 24),
        paragraphSpacing: paragraphSpacing,
        imageHeight: imageHeight,
        textDirection: textDirection,
      ).computePages(items, chapterId: 'ch');

      expect(
        describePages(actual),
        describePages(expected),
        reason: describeScenario(pageSize, textStyle, paragraphSpacing, label),
      );
    }

    /// The invariants that must hold for *any* input: every page is
    /// non-empty, and the items of each text paragraph tile its content
    /// exactly — first item starts at 0, consecutive items chain
    /// end-to-start, the last one reaches the content's length — so no
    /// character is dropped, duplicated or reordered.
    void checkInvariants(String label, List<ParagraphContent> items) {
      final pages = PageBreaker(
        pageSize: const Size(240, 120),
        textStyle: const TextStyle(fontSize: 16, height: 1.2),
        titleStyle: const TextStyle(fontSize: 24),
        paragraphSpacing: 12,
        imageHeight: 100,
        textDirection: TextDirection.ltr,
      ).computePages(items, chapterId: 'ch');

      expect(pages, isNotEmpty, reason: label);
      for (final page in pages) {
        expect(page.items, isNotEmpty, reason: label);
      }

      final byParagraph = <int, List<PageItem>>{};
      for (final page in pages) {
        for (final item in page.items) {
          byParagraph.putIfAbsent(item.paragraphIndex, () => []).add(item);
        }
      }

      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        final emitted = byParagraph[i] ?? const <PageItem>[];
        if (item is! ParagraphContent_Text) {
          expect(emitted.length, 1, reason: '$label: item $i emits once');
          continue;
        }
        if (item.content.isEmpty) {
          expect(emitted, isEmpty, reason: '$label: empty item $i');
          continue;
        }
        var expectedStart = 0;
        for (var k = 0; k < emitted.length; k++) {
          expect(
            emitted[k].startOffset ?? 0,
            expectedStart,
            reason: '$label: paragraph $i item $k chains',
          );
          expect(
            (emitted[k].endOffset ?? item.content.length) <=
                item.content.length,
            isTrue,
            reason: '$label: paragraph $i item $k in range',
          );
          expectedStart = emitted[k].endOffset ?? item.content.length;
        }
        expect(
          expectedStart,
          item.content.length,
          reason: '$label: paragraph $i reaches the end',
        );
      }
    }

    test('across the full scenario sweep', () {
      const sizes = [
        Size(240, 120),
        Size(380, 700),
        Size(100, 200),
        Size(400, 40),
        Size(320, 53),
      ];
      const styles = [
        TextStyle(fontSize: 16, height: 1.2),
        TextStyle(fontSize: 24, height: 2.4),
        TextStyle(fontSize: 18, height: 1.5, letterSpacing: 1.5),
        TextStyle(fontSize: 18),
      ];
      const spacings = [0.0, 12.0, 32.0];

      for (final size in sizes) {
        for (final style in styles) {
          for (final spacing in spacings) {
            for (var c = 0; c < cleanTextCases.length; c++) {
              checkParity(
                pageSize: size,
                textStyle: style,
                paragraphSpacing: spacing,
                items: [
                  ParagraphContent_Text(
                    id: ParagraphId(
                      original: OriginalParagraphId.source('p$c'),
                      path: [],
                    ),
                    content: cleanTextCases[c],
                  ),
                ],
                label: 'text#$c',
              );
            }
          }
        }
      }
    });

    test('across mixed title/image/text batteries', () {
      const sizes = [Size(240, 120), Size(380, 700), Size(100, 200)];
      const styles = [
        TextStyle(fontSize: 16, height: 1.2),
        TextStyle(fontSize: 24, height: 2.4),
      ];
      const spacings = [0.0, 12.0];

      for (final size in sizes) {
        for (final style in styles) {
          for (final spacing in spacings) {
            final items = <ParagraphContent>[
              for (var i = 0; i < 24; i++)
                switch (rng.nextInt(6)) {
                  0 => ParagraphContent_Title(
                    id: ParagraphId(
                      original: OriginalParagraphId.source('t$i'),
                      path: [],
                    ),
                    text: run(cjkPool, 1 + rng.nextInt(80)),
                  ),
                  1 => ParagraphContent_Image(
                    id: ParagraphId(
                      original: OriginalParagraphId.source('g$i'),
                      path: [],
                    ),
                    url: 'https://example.invalid/x.png',
                  ),
                  _ => ParagraphContent_Text(
                    id: ParagraphId(
                      original: OriginalParagraphId.source('p$i'),
                      path: [],
                    ),
                    content: cleanTextCases[rng.nextInt(cleanTextCases.length)],
                  ),
                },
            ];
            checkParity(
              pageSize: size,
              textStyle: style,
              paragraphSpacing: spacing,
              items: items,
              label: 'battery(${size.width}x${size.height})',
            );
          }
        }
      }
    });

    test('right-to-left text direction', () {
      for (final spacing in [0.0, 12.0]) {
        checkParity(
          pageSize: const Size(240, 300),
          textStyle: const TextStyle(fontSize: 18, height: 1.5),
          paragraphSpacing: spacing,
          textDirection: TextDirection.rtl,
          items: [
            // Whitespace-free, like the parity cases above: mixed
            // direction content without spaces still exercises the
            // direction plumbing through layout and caret queries.
            ParagraphContent_Text(
              id: const ParagraphId(
                original: OriginalParagraphId.source('rtl'),
                path: [],
              ),
              content: run(cjkPool, 400),
            ),
            ParagraphContent_Text(
              id: const ParagraphId(
                original: OriginalParagraphId.source('rtl2'),
                path: [],
              ),
              content: 'مرحبا${run(cjkPool, 200)}',
            ),
          ],
          label: 'rtl',
        );
      }
    });

    test('degenerate geometry falls back identically', () {
      for (final size in [const Size(0, 100), const Size(200, 0)]) {
        checkParity(
          pageSize: size,
          textStyle: const TextStyle(fontSize: 18, height: 1.5),
          paragraphSpacing: 12,
          items: [
            ParagraphContent_Text(
              id: const ParagraphId(
                original: OriginalParagraphId.source('p'),
                path: [],
              ),
              content: run(cjkPool, 300),
            ),
          ],
          label: 'degenerate(${size.width}x${size.height})',
        );
      }

      // Empty input: both return no pages at all.
      expect(
        PageBreaker(
          pageSize: const Size(240, 120),
          textStyle: const TextStyle(fontSize: 18, height: 1.5),
          titleStyle: const TextStyle(fontSize: 24),
          paragraphSpacing: 12,
          imageHeight: 100,
          textDirection: TextDirection.ltr,
        ).computePages(const [], chapterId: 'ch'),
        isEmpty,
      );
    });

    test('whitespace-heavy text keeps the coverage invariants', () {
      for (var c = 0; c < messyTextCases.length; c++) {
        checkInvariants('messy#$c', [
          ParagraphContent_Text(
            id: ParagraphId(
              original: OriginalParagraphId.source('p$c'),
              path: [],
            ),
            content: messyTextCases[c],
          ),
        ]);
      }

      // Same invariants when the gappy paragraphs interleave with titles
      // and images.
      checkInvariants('messy-battery', [
        for (var i = 0; i < 24; i++)
          switch (rng.nextInt(6)) {
            0 => ParagraphContent_Title(
              id: ParagraphId(
                original: OriginalParagraphId.source('t$i'),
                path: [],
              ),
              text: run(cjkPool, 1 + rng.nextInt(80)),
            ),
            1 => ParagraphContent_Image(
              id: ParagraphId(
                original: OriginalParagraphId.source('g$i'),
                path: [],
              ),
              url: 'https://example.invalid/x.png',
            ),
            _ => ParagraphContent_Text(
              id: ParagraphId(
                original: OriginalParagraphId.source('p$i'),
                path: [],
              ),
              content: messyTextCases[rng.nextInt(messyTextCases.length)],
            ),
          },
      ]);
    });
  });

  group('vertical justification fills pages that break at text', () {
    const pageSize = Size(240, 120);
    // PageContent.extraGap is measured against the breaker's own page
    // height (pageSize.height - 4).
    const pageHeight = 116.0;
    const body = TextStyle(fontSize: 18, height: 1.5);

    ParagraphContent text(String id, String content) => ParagraphContent_Text(
      id: ParagraphId(original: OriginalParagraphId.source(id), path: []),
      content: content,
    );

    double naturalHeight(PageContent page, double spacing) {
      var total = 0.0;
      for (var j = 0; j < page.items.length; j++) {
        if (j > 0) total += spacing;
        final tp = TextPainter(
          text: TextSpan(text: page.items[j].visibleText, style: body),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: pageSize.width);
        total += tp.height;
        tp.dispose();
      }
      return total;
    }

    test('a text-break page distributes its leftover into the gaps', () {
      final breaker = PageBreaker(
        pageSize: pageSize,
        textStyle: body,
        titleStyle: const TextStyle(fontSize: 24),
        paragraphSpacing: 12,
        imageHeight: 100,
        textDirection: TextDirection.ltr,
      );
      final pages = breaker.computePages([
        for (var i = 0; i < 30; i++) text('p$i', '短句$i。'),
      ], chapterId: 'c');

      // Every page except the last breaks because the next one-line
      // paragraph (12 spacing + 27 line) does not fit its 11 leftover
      // pixels, so each carries 11 / 2 = 5.5 extra gap pixels.
      expect(pages.length, 10);
      for (final page in pages.take(pages.length - 1)) {
        expect(page.items.length, 3);
        expect(page.extraGap, closeTo(5.5, 0.01));
        final gaps = page.items.length - 1;
        expect(
          naturalHeight(page, 12) + gaps * page.extraGap,
          closeTo(pageHeight, 0.01),
          reason: 'the stretched gaps fill the page to its bottom',
        );
      }

      // The chapter's final page ends where its content does.
      expect(pages.last.extraGap, 0);
    });

    test('a page before a kept-whole title keeps its natural space', () {
      final breaker = PageBreaker(
        pageSize: pageSize,
        textStyle: body,
        titleStyle: const TextStyle(fontSize: 24),
        paragraphSpacing: 12,
        imageHeight: 100,
        textDirection: TextDirection.ltr,
      );
      final pages = breaker.computePages([
        for (var i = 0; i < 20; i++) text('p$i', '短句$i。'),
        ParagraphContent_Title(
          id: const ParagraphId(
            original: OriginalParagraphId.source('heading'),
            path: [],
          ),
          text: '很长很长很长很长很长很长的标题',
        ),
        text('after', '後文。'),
      ], chapterId: 'c');

      // computePages stamps each item with its source id's string form
      // (ParagraphId.toStringValue), not the bare source value.
      const headingId = ParagraphId(
        original: OriginalParagraphId.source('heading'),
        path: [],
      );
      final titlePage = pages.indexWhere(
        (p) => p.items.any((i) => i.paragraphId == headingId.toStringValue()),
      );
      expect(titlePage, greaterThan(0), reason: 'the title moved off a page');
      // The title starts its own page by design; the page it left behind
      // keeps its trailing space instead of stretching its gaps.
      expect(pages[titlePage - 1].extraGap, 0);
      expect(
        pages[titlePage].items.first.paragraphId,
        headingId.toStringValue(),
      );
      // The chapter-final page is never justified either.
      expect(pages.last.extraGap, 0);
    });
  });
}

/// Frozen copy of the original (quadratic) `PageBreaker`, verbatim from the
/// substring-re-layout implementation the line-metrics rewrite replaced —
/// except for one premature `dispose()` removed from the `fitLines == 0`
/// branch: the original disposed the painter and then queried it, which
/// asserts in debug builds on pages shorter than a single line (undefined
/// in release). See the comment in that branch.
///
/// It exists only as the behavioural reference for the parity tests above:
/// any intentional change to pagination semantics must be applied to both
/// classes and this comment. Do not optimise or "fix" anything here.
class _ReferencePageBreaker {
  _ReferencePageBreaker({
    required this.pageSize,
    required this.textStyle,
    required this.titleStyle,
    required this.paragraphSpacing,
    required this.imageHeight,
    required this.textDirection,
  });

  final Size pageSize;
  final TextStyle textStyle;
  final TextStyle titleStyle;
  final double paragraphSpacing;
  final double imageHeight;
  final TextDirection textDirection;

  List<PageContent> computePages(
    List<ParagraphContent> items, {
    String chapterId = '',
  }) {
    if (items.isEmpty) return const [];

    final double w = pageSize.width;
    final double h = pageSize.height - 4.0;

    if (w <= 0 || h <= 0) {
      return [
        PageContent(
          chapterId: chapterId,
          items: [
            for (int i = 0; i < items.length; i++)
              PageItem(
                source: items[i],
                paragraphIndex: i,
                paragraphId: items[i].id.toStringValue(),
              ),
          ],
        ),
      ];
    }

    final List<PageContent> pages = [];
    List<PageItem> cur = [];
    double remaining = h;

    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      final spacing = cur.isEmpty ? 0.0 : paragraphSpacing;

      if (item is ParagraphContent_Title) {
        final th = _measureTitle(item.text, w);
        if (remaining - spacing < th && cur.isNotEmpty) {
          pages.add(PageContent(chapterId: chapterId, items: cur));
          cur = [];
          remaining = h;
        }
        final sp = cur.isEmpty ? 0.0 : paragraphSpacing;
        remaining -= sp + th;
        cur.add(
          PageItem(
            source: item,
            paragraphIndex: i,
            paragraphId: item.id.toStringValue(),
          ),
        );
      } else if (item is ParagraphContent_Image) {
        if (remaining - spacing < imageHeight && cur.isNotEmpty) {
          pages.add(PageContent(chapterId: chapterId, items: cur));
          cur = [];
          remaining = h;
        }
        final sp = cur.isEmpty ? 0.0 : paragraphSpacing;
        remaining -= sp + imageHeight;
        cur.add(
          PageItem(
            source: item,
            paragraphIndex: i,
            paragraphId: item.id.toStringValue(),
          ),
        );
      } else if (item is ParagraphContent_Text) {
        _layoutText(
          chapterId: chapterId,
          text: item.content,
          paragraphIndex: i,
          paragraphId: item.id.toStringValue(),
          source: item,
          width: w,
          pageHeight: h,
          spacing: spacing,
          remaining: remaining,
          currentItems: cur,
          pages: pages,
          onUpdate: (newItems, newRemaining) {
            cur = newItems;
            remaining = newRemaining;
          },
        );
      }
    }

    if (cur.isNotEmpty) {
      pages.add(PageContent(chapterId: chapterId, items: cur));
    }

    return pages.isEmpty
        ? [
            PageContent(
              chapterId: chapterId,
              items: [
                for (int i = 0; i < items.length; i++)
                  PageItem(
                    source: items[i],
                    paragraphIndex: i,
                    paragraphId: items[i].id.toStringValue(),
                  ),
              ],
            ),
          ]
        : pages;
  }

  double _measureTitle(String text, double maxWidth) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: titleStyle),
      textDirection: textDirection,
      maxLines: null,
    )..layout(maxWidth: maxWidth);
    final result = tp.height;
    tp.dispose();
    return result;
  }

  void _layoutText({
    required String chapterId,
    required String text,
    required int paragraphIndex,
    required String paragraphId,
    required ParagraphContent_Text source,
    required double width,
    required double pageHeight,
    required double spacing,
    required double remaining,
    required List<PageItem> currentItems,
    required List<PageContent> pages,
    required void Function(List<PageItem>, double) onUpdate,
  }) {
    int charStart = 0;

    while (charStart < text.length) {
      final substring = text.substring(charStart);
      final tp = TextPainter(
        text: TextSpan(text: substring, style: textStyle),
        textDirection: textDirection,
        maxLines: null,
      )..layout(maxWidth: width);

      final fullH = tp.height;
      final sp = currentItems.isEmpty ? 0.0 : paragraphSpacing;
      final space = remaining - sp;

      if (space >= fullH) {
        tp.dispose();
        remaining -= sp + fullH;
        currentItems.add(
          PageItem(
            source: source,
            paragraphIndex: paragraphIndex,
            paragraphId: paragraphId,
            startOffset: charStart == 0 ? null : charStart,
          ),
        );
        onUpdate(currentItems, remaining);
        return;
      }

      if (space <= 0 ||
          (space < tp.preferredLineHeight && currentItems.isNotEmpty)) {
        tp.dispose();
        pages.add(PageContent(chapterId: chapterId, items: currentItems));
        currentItems = [];
        remaining = pageHeight;
        continue;
      }

      final lineMetrics = tp.computeLineMetrics();
      double accH = 0;
      int fitLines = 0;
      for (final line in lineMetrics) {
        if (accH + line.height > space + 0.5) break;
        accH += line.height;
        fitLines++;
      }

      if (fitLines == 0) {
        if (currentItems.isNotEmpty) {
          tp.dispose();
          pages.add(PageContent(chapterId: chapterId, items: currentItems));
          currentItems = [];
          remaining = pageHeight;
          continue;
        }
        fitLines = 1;
        if (lineMetrics.isEmpty) {
          currentItems.add(
            PageItem(
              source: source,
              paragraphIndex: paragraphIndex,
              paragraphId: paragraphId,
              startOffset: charStart == 0 ? null : charStart,
            ),
          );
          tp.dispose();
          pages.add(PageContent(chapterId: chapterId, items: currentItems));
          currentItems = [];
          remaining = pageHeight;
          onUpdate(currentItems, remaining);
          return;
        }
        // Pages shorter than a single line reach this fall-through. The
        // original disposed the painter right before querying it below,
        // which asserts in debug builds (and was undefined in release).
        // Keeping the painter alive makes the path deterministic; the
        // rewrite does the same.
      }

      final lastLine = lineMetrics[fitLines - 1];
      final bottom = lastLine.baseline + lastLine.descent;
      final position = tp.getPositionForOffset(Offset(width, bottom - 1));
      int splitChar = charStart + position.offset;
      if (splitChar <= charStart) splitChar = charStart + 1;
      if (splitChar > text.length) splitChar = text.length;

      tp.dispose();

      currentItems.add(
        PageItem(
          source: source,
          paragraphIndex: paragraphIndex,
          paragraphId: paragraphId,
          startOffset: charStart == 0 ? null : charStart,
          endOffset: splitChar,
        ),
      );

      pages.add(PageContent(chapterId: chapterId, items: currentItems));
      currentItems = [];
      remaining = pageHeight;
      charStart = splitChar;
    }

    onUpdate(currentItems, remaining);
  }
}

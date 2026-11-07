import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/widgets/comment_badge.dart';
import 'package:langhuan/features/bookshelf/widgets/page_breaker.dart';
import 'package:langhuan/features/bookshelf/widgets/page_content_view.dart';
import 'package:langhuan/features/bookshelf/widgets/reader_text_indent.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/src/rust/api/types.dart';

const _style = TextStyle(fontSize: 20, height: 1.5, fontFamily: 'Ahem');

Widget _host(Widget child, double scale) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: ThemeData(textTheme: const TextTheme(bodyLarge: _style)),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'first-line spacer changes layout without changing text at $scale',
      (tester) async {
        const text = '甲乙丙丁戊己庚辛壬癸甲乙丙丁戊己庚辛壬癸';
        await tester.pumpWidget(
          _host(
            const SizedBox(
              width: 160,
              child: BadgedText(text: text, style: _style, firstLineIndent: 2),
            ),
            scale,
          ),
        );
        final paragraph = tester.renderObject<RenderParagraph>(
          find.byType(RichText).first,
        );
        // Only the renderer has a leading placeholder; source text is intact.
        final textWidget = tester.widget<BadgedText>(find.byType(BadgedText));
        expect(textWidget.text, text);
        final boxes = paragraph.getBoxesForSelection(
          const TextSelection(baseOffset: 1, extentOffset: text.length + 1),
        );
        expect(boxes.length, greaterThan(1));
        expect(boxes.first.left, closeTo(40 * scale, .5));
        for (final line in boxes.skip(1)) {
          expect(line.left, closeTo(0, .5));
        }
        expect(tester.takeException(), isNull);
      },
    );

    for (final badge in [false, true]) {
      testWidgets(
        'pagination keeps source offsets and indents only the first fragment: $scale/$badge',
        (tester) async {
          final text = List.filled(16, '甲乙丙丁😀戊己庚辛。').join();
          final source = ParagraphContent.text(
            id: const ParagraphId(
              original: OriginalParagraphId.source('p'),
              path: [],
            ),
            content: text,
            layout: const ParagraphLayout(firstLineIndent: 2),
            commentCount: badge ? 120 : null,
          );
          const size = Size(260, 240);
          // Use the exact badge measurement of the rendered theme and locale.
          await tester.pumpWidget(_host(const SizedBox(), scale));
          final context = tester.element(find.byType(Scaffold));
          final pages =
              PageBreaker(
                pageSize: size,
                textStyle: _style,
                titleStyle: _style,
                paragraphSpacing: 16,
                imageHeight: 100,
                textDirection: TextDirection.ltr,
                textScaler: TextScaler.linear(scale),
                locale: const Locale('en'),
              ).computePages(
                [source],
                commentBadgeSizes: {
                  if (badge)
                    source.id.toStringValue(): CommentBadge.inlineSize(
                      context,
                      120,
                    ),
                },
              );
          expect(pages.length, greaterThan(1));
          expect(
            pages.expand((p) => p.items).map((p) => p.visibleText).join(),
            text,
          );
          var offset = 0;
          for (final page in pages) {
            expect(page.firstCharOffset, offset);
            final item = page.items.single;
            expect(
              PageBreaker.pageForPosition(pages, item.paragraphId, offset),
              pages.indexOf(page),
            );
            expect(item.startOffset ?? 0, offset);
            final units = item.visibleText.codeUnits;
            expect(units.first >= 0xdc00 && units.first <= 0xdfff, isFalse);
            expect(units.last >= 0xd800 && units.last <= 0xdbff, isFalse);
            offset += item.visibleText.length;
            await tester.pumpWidget(
              _host(
                SizedBox.fromSize(
                  size: size,
                  child: PageContentView(
                    page: page,
                    lineHeight: 1.5,
                    commentBadgeIds: badge ? {item.paragraphId} : {},
                  ),
                ),
                scale,
              ),
            );
            final rendered = tester.widget<BadgedText>(
              find.byType(BadgedText).first,
            );
            expect(rendered.firstLineIndent, page == pages.first ? 2 : 0);
            final column = find
                .descendant(
                  of: find.byType(PageContentView),
                  matching: find.byType(Column),
                )
                .first;
            expect(
              tester.getSize(column).height,
              lessThanOrEqualTo(size.height + .5),
            );
            expect(tester.takeException(), isNull);
          }
          expect(offset, text.length);
        },
      );
    }
  }

  testWidgets(
    'a short badged paragraph keeps its first inline unit beside the indent',
    (tester) async {
      await tester.pumpWidget(
        _host(
          const SizedBox(
            width: 160,
            child: BadgedText(
              text: '甲',
              style: _style,
              firstLineIndent: 8,
              commentCount: 120,
            ),
          ),
          2,
        ),
      );
      final paragraph = tester.getRect(find.byType(RichText).first);
      final badge = tester.widget<CommentBadge>(find.byType(CommentBadge));
      expect(badge.compact, isTrue);
      expect(paragraph.height, lessThan(80));
      final tail = tester.getRect(find.text('甲'));
      expect(tail.left, greaterThan(paragraph.left));
      expect(tail.right, lessThanOrEqualTo(paragraph.right + .5));
      expect(tester.takeException(), isNull);
    },
  );

  test('large indents leave room for a glyph on narrow viewports', () {
    expect(
      ReaderTextIndent.width(8, _style, const TextScaler.linear(2), 100),
      30,
    );
    expect(ReaderTextIndent.width(2, _style, TextScaler.noScaling, 10), 0);
  });
}

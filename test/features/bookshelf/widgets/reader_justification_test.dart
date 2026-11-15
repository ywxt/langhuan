import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/widgets/comment_badge.dart';
import 'package:langhuan/features/bookshelf/widgets/page_breaker.dart';
import 'package:langhuan/features/bookshelf/widgets/page_content_view.dart';
import 'package:langhuan/features/bookshelf/widgets/paragraph_view.dart';
import 'package:langhuan/features/bookshelf/widgets/reader_typography.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/src/rust/api/types.dart';

const _style = TextStyle(fontFamily: 'Ahem', fontSize: 20, height: 1.5);
const _id = ParagraphId(original: OriginalParagraphId.source('p'), path: []);

Widget _host(Widget child, {double scale = 1}) => MaterialApp(
  theme: ThemeData(textTheme: const TextTheme(bodyLarge: _style)),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: Scaffold(
      body: Align(alignment: Alignment.topLeft, child: child),
    ),
  ),
);

void main() {
  testWidgets(
    'punctuation wrapping fills soft lines but leaves the last natural',
    (tester) async {
      const text = '甲乙丙丁，戊己';
      await tester.pumpWidget(
        _host(
          const SizedBox(
            width: 90,
            child: ParagraphView(
              paragraph: ParagraphContent.text(id: _id, content: text),
            ),
          ),
        ),
      );
      final paragraph = tester.renderObject<RenderParagraph>(
        find.byType(RichText),
      );
      final boxes = paragraph.getBoxesForSelection(
        const TextSelection(baseOffset: 0, extentOffset: text.length),
      );
      expect(boxes.length, 2);
      expect(boxes.first.right, closeTo(90, .01));
      expect(boxes.last.right, lessThan(90));
      expect(tester.widget<BadgedText>(find.byType(BadgedText)).text, text);
    },
  );

  for (final scale in [1.0, 1.5, 2.0]) {
    testWidgets(
      'continuation fills its last line without extra height at $scale',
      (tester) async {
        const text = '甲乙丙';
        await tester.pumpWidget(
          _host(
            SizedBox(
              width: 90 * scale,
              child: const BadgedText(
                text: text,
                style: _style,
                textAlign: ReaderTypography.bodyAlign,
                continuesOnNextPage: true,
              ),
            ),
            scale: scale,
          ),
        );
        final rich = tester.widget<RichText>(find.byType(RichText));
        final paragraph = tester.renderObject<RenderParagraph>(
          find.byType(RichText),
        );
        final boxes = paragraph.getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: text.length),
        );
        expect(boxes.single.right, closeTo(90 * scale, .5));
        expect(paragraph.size.height, closeTo(30 * scale, .01));
        expect(rich.text.toPlainText(includePlaceholders: false), text);
        expect(tester.widget<Text>(find.byType(Text)).semanticsLabel, text);
        expect(tester.takeException(), isNull);
      },
    );

    for (final badge in [false, true]) {
      testWidgets(
        'pagination preserves indented fragments and badges at $scale/$badge',
        (tester) async {
          final text = List.filled(12, '甲乙丙丁，戊己庚辛。壬癸').join();
          final source = ParagraphContent.text(
            id: _id,
            content: text,
            layout: const ParagraphLayout(firstLineIndent: 2),
            commentCount: badge ? 120 : null,
          );
          await tester.pumpWidget(_host(const SizedBox(), scale: scale));
          final context = tester.element(find.byType(Scaffold));
          const size = Size(260, 200);
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
                    _id.toStringValue(): CommentBadge.inlineSize(context, 120),
                },
              );
          expect(pages.length, greaterThan(1));
          expect(
            pages.expand((p) => p.items).map((p) => p.visibleText).join(),
            text,
          );
          var offset = 0;
          for (final page in pages) {
            final item = page.items.single;
            expect(item.startOffset ?? 0, offset);
            offset += item.visibleText.length;
            await tester.pumpWidget(
              _host(
                SizedBox.fromSize(
                  size: size,
                  child: PageContentView(
                    page: page,
                    lineHeight: 1.5,
                    commentBadgeIds: badge ? {_id.toStringValue()} : {},
                  ),
                ),
                scale: scale,
              ),
            );
            final rendered = tester.widget<BadgedText>(find.byType(BadgedText));
            expect(rendered.firstLineIndent, page == pages.first ? 2 : 0);
            expect(rendered.continuesOnNextPage, page != pages.last);
            final richFinder = find.byType(RichText).first;
            final paragraph = tester.renderObject<RenderParagraph>(richFinder);
            expect(paragraph.size.height, lessThanOrEqualTo(size.height));
            if (page != pages.last) {
              final boxes = paragraph.getBoxesForSelection(
                TextSelection(
                  baseOffset: page == pages.first ? 1 : 0,
                  extentOffset:
                      (page == pages.first ? 1 : 0) + item.visibleText.length,
                ),
              );
              expect(boxes.last.right, closeTo(size.width, .5));
              expect(find.byType(CommentBadge), findsNothing);
            }
            expect(tester.takeException(), isNull);
          }
          expect(offset, text.length);
          expect(
            find.byType(CommentBadge),
            badge ? findsOneWidget : findsNothing,
          );
        },
      );
    }
  }

  testWidgets('explicit newline at a page boundary stays a hard line break', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const SizedBox(
          width: 90,
          child: BadgedText(
            text: '甲乙丙\n',
            style: _style,
            textAlign: ReaderTypography.bodyAlign,
            continuesOnNextPage: true,
          ),
        ),
      ),
    );
    final paragraph = tester.renderObject<RenderParagraph>(
      find.byType(RichText),
    );
    final boxes = paragraph.getBoxesForSelection(
      const TextSelection(baseOffset: 0, extentOffset: 3),
    );
    expect(boxes.first.right, lessThan(90));
    expect(tester.widget<Text>(find.byType(Text)).maxLines, isNull);
  });
}

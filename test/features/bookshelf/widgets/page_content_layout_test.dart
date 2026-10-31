import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/widgets/comment_badge.dart';
import 'package:langhuan/features/bookshelf/widgets/page_breaker.dart';
import 'package:langhuan/features/bookshelf/widgets/page_content_view.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import 'package:langhuan/src/rust/api/types.dart';

void main() {
  const compressionStyle = TextStyle(
    fontFamily: 'Ahem',
    fontSize: 20,
    height: 1,
  );
  CommentParagraphLayout layoutFor(String text, double badgeWidth) =>
      CommentParagraphLayout.resolve(
        text: text,
        style: compressionStyle,
        badgeSize: Size(badgeWidth, 20),
        width: 200,
        textScaler: TextScaler.noScaling,
        direction: TextDirection.ltr,
        locale: null,
        align: TextAlign.start,
      );

  test('badge spacing tightens before paragraph tracking', () {
    final text = List.filled(18, '文').join();
    final layout = layoutFor(text, 44);
    expect(layout.style.letterSpacing, isNull);
    expect(layout.gap, inInclusiveRange(2, 4.01));
    expect(layoutFor('短正文', 44).gap, CommentBadge.inlineGap);
  });

  test('compression applies to every page fragment of the paragraph', () {
    final text = List.filled(18, '文').join();
    final layout = layoutFor(text, 46);
    expect(layout.style.letterSpacing, inInclusiveRange(-1, -0.01));
    expect(layout.style.fontSize, compressionStyle.fontSize);
    final paragraph = ParagraphContent.text(
      id: const ParagraphId(
        original: OriginalParagraphId.source('compressed'),
        path: [],
      ),
      content: text,
      commentCount: 12,
    );
    final pages =
        PageBreaker(
          pageSize: const Size(200, 24),
          textStyle: compressionStyle,
          titleStyle: compressionStyle,
          paragraphSpacing: 0,
          imageHeight: 20,
          textDirection: TextDirection.ltr,
        ).computePages(
          [paragraph],
          commentBadgeSizes: {paragraph.id.toStringValue(): const Size(46, 20)},
        );
    expect(pages, hasLength(2));
    for (final item in pages.expand((p) => p.items)) {
      expect(item.letterSpacing, layout.style.letterSpacing);
      expect(item.badgeGap, layout.gap);
    }
    expect(pages.expand((p) => p.items).map((p) => p.visibleText).join(), text);
  });

  test('excessive compression falls back to wrapping', () {
    final layout = layoutFor(List.filled(20, '文').join(), 46);
    expect(layout.style, compressionStyle);
    expect(layout.gap, CommentBadge.inlineGap);
  });

  test('the attached tail preserves emoji clusters and trailing spaces', () {
    expect(BadgedText.tailText('正文👨‍👩‍👧‍👦  '), '👨‍👩‍👧‍👦  ');
    expect(BadgedText.tailText('Cafe\u0301'), 'e\u0301');
    expect(BadgedText.tailText('正文！”  '), '文！”  ');
  });
  test('a full final line moves its tail text together with the badge', () {
    const style = TextStyle(fontFamily: 'Ahem', fontSize: 20, height: 1);
    const text = '一二三四五六七八九十';
    final painter =
        TextPainter(
          text: BadgedText.inlineSpan(text, style, const SizedBox()),
          textDirection: TextDirection.ltr,
        )..setPlaceholderDimensions(const [
          PlaceholderDimensions(
            size: Size(80, 20),
            alignment: PlaceholderAlignment.middle,
          ),
        ]);
    painter.layout(maxWidth: 200);
    final badge = painter.inlinePlaceholderBoxes!.single;
    expect(painter.computeLineMetrics(), hasLength(2));
    expect(badge.top, 20);
    expect(BadgedText.tailText(text), '十');
    painter.dispose();

    final paragraph = ParagraphContent.text(
      id: const ParagraphId(
        original: OriginalParagraphId.source('tail'),
        path: [],
      ),
      content: text,
      commentCount: 9,
    );
    final pages =
        PageBreaker(
          pageSize: const Size(200, 24),
          textStyle: style,
          titleStyle: style,
          paragraphSpacing: 0,
          imageHeight: 20,
          textDirection: TextDirection.ltr,
        ).computePages(
          [paragraph],
          commentBadgeSizes: {paragraph.id.toStringValue(): const Size(60, 20)},
        );
    expect(pages, hasLength(2));
    expect(pages.first.items.single.endOffset, isNotNull);
    expect(pages.last.items.single.endOffset, isNull);
    expect(pages.last.items.single.visibleText, isNotEmpty);
    expect(pages.expand((p) => p.items).map((p) => p.visibleText).join(), text);
  });

  for (final fontScale in [1.0, 1.5]) {
    for (final systemScale in [1.0, 1.3]) {
      testWidgets(
        'commented phone pages fit at font $fontScale / system $systemScale',
        (tester) async {
          const pageSize = Size(363.4, 844.6);
          const screenSize = Size(411.4, 914.3);
          tester.view.physicalSize = screenSize;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final theme = ThemeData(
            textTheme: const TextTheme(
              bodyLarge: TextStyle(
                fontSize: 24,
                height: 1.8,
                fontFamily: 'Ahem',
              ),
              headlineSmall: TextStyle(
                fontSize: 30,
                height: 1.3,
                fontFamily: 'Ahem',
              ),
            ),
          );
          final scaler = TextScaler.linear(systemScale);
          late BuildContext readerContext;
          Widget host(Widget child) => MaterialApp(
            theme: theme,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: MediaQuery(
              data: MediaQueryData(size: screenSize, textScaler: scaler),
              child: Scaffold(
                body: Builder(
                  builder: (context) {
                    readerContext = context;
                    return Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox.fromSize(size: pageSize, child: child),
                    );
                  },
                ),
              ),
            ),
          );
          await tester.pumpWidget(host(const SizedBox()));
          final paragraphs = [
            for (var i = 0; i < 18; i++)
              ParagraphContent.text(
                id: ParagraphId(
                  original: OriginalParagraphId.source('$i'),
                  path: [],
                ),
                content: List.filled(
                  1 + i % 4,
                  '這是一段接近行尾的正文，評論徽標也會佔用空間。',
                ).join(),
                commentCount: 147 + i,
              ),
          ];
          final badgeIds = paragraphs.map((p) => p.id.toStringValue()).toSet();
          final breaker = PageBreaker(
            pageSize: pageSize,
            textStyle: theme.textTheme.bodyLarge!.copyWith(
              fontSize: 24 * fontScale,
            ),
            titleStyle: theme.textTheme.headlineSmall!.copyWith(
              fontSize: 30 * fontScale,
            ),
            paragraphSpacing: 16,
            imageHeight: 200,
            textDirection: TextDirection.ltr,
            textScaler: scaler,
            locale: Localizations.localeOf(readerContext),
          );
          final pages = breaker.computePages(
            paragraphs,
            commentBadgeSizes: {
              for (final paragraph in paragraphs)
                paragraph.id.toStringValue(): CommentBadge.inlineSize(
                  readerContext,
                  paragraph.commentCount!,
                ),
            },
          );
          var badges = 0;
          for (final page in pages) {
            await tester.pumpWidget(
              host(
                PageContentView(
                  page: page,
                  fontScale: fontScale,
                  commentBadgeIds: badgeIds,
                ),
              ),
            );
            expect(tester.takeException(), isNull);
            badges += find.byType(CommentBadge).evaluate().length;
            for (final element in find.byType(BadgedText).evaluate()) {
              final widget = element.widget as BadgedText;
              if (widget.commentCount == null) continue;
              final item = page.items.singleWhere(
                (p) => p.visibleText == widget.text,
              );
              expect(item.endOffset, isNull);
            }
          }
          expect(badges, paragraphs.length);
          for (var i = 0; i < paragraphs.length; i++) {
            final fragments = pages
                .expand((p) => p.items)
                .where((p) => p.paragraphIndex == i)
                .toList();
            expect(fragments.every((p) => p.visibleText.isNotEmpty), isTrue);
            expect(fragments.last.endOffset, isNull);
            expect(
              fragments.map((p) => p.visibleText).join(),
              (paragraphs[i] as ParagraphContent_Text).content,
            );
          }
        },
      );
    }
  }
}

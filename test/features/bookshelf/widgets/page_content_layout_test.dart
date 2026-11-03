import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/widgets/comment_badge.dart';
import 'package:langhuan/features/bookshelf/widgets/page_breaker.dart';
import 'package:langhuan/features/bookshelf/widgets/page_content_view.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import 'package:langhuan/src/rust/api/types.dart';

void main() {
  for (final fontSize in [10.0, 32.0]) {
    for (final scale in [1.0, 1.3]) {
      for (final height in [1.0, 1.8, 2.4]) {
        testWidgets(
          'inline tail shares the text baseline at $fontSize/$scale/$height',
          (tester) async {
            await tester.pumpWidget(
              MaterialApp(
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: Scaffold(
                  body: MediaQuery(
                    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: 500,
                        child: BadgedText(
                          text: '甲乙丙',
                          style: TextStyle(
                            fontFamily: 'Ahem',
                            fontSize: fontSize,
                            height: height,
                          ),
                          commentCount: 12,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            final outerFinder = find.byWidgetPredicate(
              (widget) =>
                  widget is RichText &&
                  widget.text.toPlainText().contains('\uFFFC'),
            );
            final outer = tester.renderObject<RenderParagraph>(outerFinder);
            final tail = tester.renderObject<RenderParagraph>(find.text('丙'));
            double baseline(RenderParagraph paragraph) => paragraph
                .localToGlobal(
                  Offset(
                    0,
                    paragraph.getDryBaseline(
                      paragraph.constraints,
                      TextBaseline.alphabetic,
                    )!,
                  ),
                )
                .dy;
            // Allow subpixel rounding of scaled inline placeholders.
            expect(baseline(tail), closeTo(baseline(outer), 0.51));
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
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
    expect(layout.compact, isFalse);
    expect(layout.style.letterSpacing, isNull);
    expect(layout.gap, inInclusiveRange(2, 4.01));
    expect(layoutFor('短正文', 44).gap, CommentBadge.inlineGap);
  });

  test('a tight last line falls back to the icon-only badge', () {
    // 18 glyphs = 10 + 8; the last line has 40px free but the full badge
    // unit needs 78. The icon capsule's 52px unit fits (140 + 52 = 192),
    // keeping the final character on its line instead of wrapping both
    // to a near-empty extra line.
    final layout = layoutFor(List.filled(18, '文').join(), 58);
    expect(layout.compact, isTrue);
    expect(layout.gap, CommentBadge.inlineGap);
    expect(layout.style, compressionStyle);
    expect(
      layout.badgeSize(const Size(58, 20)),
      const Size(32, 18), // capsule 26 + gap 6, per inlineSize's convention.
    );
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
      expect(item.badgeCompact, isFalse);
    }
    expect(pages.expand((p) => p.items).map((p) => p.visibleText).join(), text);
  });

  test('compact badges paginate on the paragraph line grid', () {
    final text = List.filled(18, '文').join();
    final paragraph = ParagraphContent.text(
      id: const ParagraphId(
        original: OriginalParagraphId.source('compact'),
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
          commentBadgeSizes: {paragraph.id.toStringValue(): const Size(58, 20)},
        );
    // The full badge would need a third line — and a third page.
    expect(pages, hasLength(2));
    for (final item in pages.expand((p) => p.items)) {
      expect(item.badgeCompact, isTrue);
      expect(item.letterSpacing, isNull);
      expect(item.badgeGap, CommentBadge.inlineGap);
    }
    expect(pages.expand((p) => p.items).map((p) => p.visibleText).join(), text);
  });

  testWidgets('the compact badge drops the count label, not the count', (
    tester,
  ) async {
    Future<void> pump(int glyphCount) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                child: BadgedText(
                  text: List.filled(glyphCount, '文').join(),
                  style: compressionStyle,
                  commentCount: 12,
                ),
              ),
            ),
          ),
        ),
      );
    }

    // 18 glyphs: the last line cannot fit the full badge, so the paragraph
    // falls back to the icon-only capsule and keeps its two lines.
    await pump(18);
    expect(
      tester.widget<CommentBadge>(find.byType(CommentBadge)).compact,
      isTrue,
    );
    expect(find.text('12'), findsNothing);
    expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);
    expect(tester.getSize(find.byType(BadgedText)).height, closeTo(40, 1.01));
    final handle = tester.ensureSemantics();
    await tester.pumpAndSettle();
    // No label text, but the count stays reachable for assistive tech.
    expect(find.bySemanticsLabel(RegExp(r'12')), findsWidgets);
    handle.dispose();

    // Roomy paragraph: the full badge with its count label stays.
    await pump(5);
    expect(
      tester.widget<CommentBadge>(find.byType(CommentBadge)).compact,
      isFalse,
    );
    expect(find.text('12'), findsOneWidget);
    expect(tester.getSize(find.byType(BadgedText)).height, closeTo(20, 1.01));
  });

  test('excessive compression falls back to wrapping', () {
    final layout = layoutFor(List.filled(20, '文').join(), 46);
    expect(layout.compact, isFalse);
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
        )..setPlaceholderDimensions([
          BadgedText.tailDimensions(
            text,
            style,
            const Size(60, 20),
            TextDirection.ltr,
            null,
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

  testWidgets('extraGap stretches the inter-item gap when rendering', (
    tester,
  ) async {
    ParagraphContent_Text src(String id) => ParagraphContent_Text(
      id: ParagraphId(original: OriginalParagraphId.source(id), path: const []),
      content: '正文',
    );
    PageContent build(double extraGap) => PageContent(
      chapterId: 'c',
      items: [
        PageItem(source: src('a'), paragraphIndex: 0, paragraphId: 'a'),
        PageItem(source: src('b'), paragraphIndex: 1, paragraphId: 'b'),
      ],
      extraGap: extraGap,
    );

    Widget host(PageContent page) => MaterialApp(
      theme: ThemeData(
        textTheme: const TextTheme(
          bodyLarge: TextStyle(fontSize: 20, height: 1.0, fontFamily: 'Ahem'),
        ),
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 200,
            height: 200,
            child: PageContentView(
              page: page,
              paragraphSpacing: 12,
              // Defaults would override the theme: keep the 1.0 line height
              // this test's arithmetic assumes.
              lineHeight: 1.0,
              letterSpacing: 0.0,
            ),
          ),
        ),
      ),
    );

    double itemStep() {
      final tops =
          find
              .byType(BadgedText)
              .evaluate()
              .map(
                (e) =>
                    (e.renderObject as RenderBox).localToGlobal(Offset.zero).dy,
              )
              .toList()
            ..sort();
      expect(tops.length, 2);
      return tops[1] - tops[0];
    }

    await tester.pumpWidget(host(build(0)));
    // One 20px line plus the 12px gap.
    expect(itemStep(), closeTo(32, 0.01));
    await tester.pumpWidget(host(build(5)));
    expect(itemStep(), closeTo(37, 0.01));
    expect(tester.takeException(), isNull);
  });
}

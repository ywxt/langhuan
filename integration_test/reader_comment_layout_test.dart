import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:langhuan/features/bookshelf/widgets/comment_badge.dart';
import 'package:langhuan/features/bookshelf/widgets/page_breaker.dart';
import 'package:langhuan/features/bookshelf/widgets/page_content_view.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import 'package:langhuan/src/rust/api/types.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('device font tail uses the same baseline as the preceding text', (
    tester,
  ) async {
    for (final scale in [1.0, 1.3]) {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: const Align(
                alignment: Alignment.topLeft,
                child: BadgedText(
                  text: '正文對齊',
                  style: TextStyle(fontSize: 32, height: 1.8),
                  commentCount: 36,
                ),
              ),
            ),
          ),
        ),
      );
      final outer = tester.renderObject<RenderParagraph>(
        find.byWidgetPredicate(
          (widget) =>
              widget is RichText &&
              widget.text.toPlainText().contains('\uFFFC'),
        ),
      );
      final tail = tester.renderObject<RenderParagraph>(find.text('齊'));
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
      expect(baseline(tail), closeTo(baseline(outer), 0.51));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('comment badges fit device pages across reading text sizes', (
    tester,
  ) async {
    for (final fontScale in [1.0, 1.5, 2.0]) {
      for (final systemScale in [1.0, 1.3]) {
        late BuildContext readerContext;
        late Size pageSize;
        Widget host(Widget child) => MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SafeArea(
              child: MediaQuery.withClampedTextScaling(
                minScaleFactor: systemScale,
                maxScaleFactor: systemScale,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      readerContext = context;
                      pageSize = constraints.biggest;
                      return Align(alignment: Alignment.topLeft, child: child);
                    },
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpWidget(host(const SizedBox()));
        final paragraphs = [
          for (var i = 0; i < 12; i++)
            ParagraphContent.text(
              id: ParagraphId(
                original: OriginalParagraphId.source('$i'),
                path: [],
              ),
              content: List.filled(
                1 + i % 5,
                '評論徽標應跟隨末尾文字換行，在頁底保持完整，不會單獨佔一行。👨‍👩‍👧‍👦',
              ).join(),
              commentCount: i + 147,
            ),
        ];
        final theme = Theme.of(readerContext);
        final pages =
            PageBreaker(
              pageSize: pageSize,
              textStyle: theme.textTheme.bodyLarge!.copyWith(
                fontSize: theme.textTheme.bodyLarge!.fontSize! * fontScale,
                height: 1.8,
              ),
              titleStyle: theme.textTheme.headlineSmall!,
              paragraphSpacing: 16,
              imageHeight: 200,
              textDirection: Directionality.of(readerContext),
              textScaler: MediaQuery.textScalerOf(readerContext),
              locale: Localizations.localeOf(readerContext),
            ).computePages(
              paragraphs,
              commentBadgeSizes: {
                for (final p in paragraphs)
                  p.id.toStringValue(): CommentBadge.inlineSize(
                    readerContext,
                    p.commentCount!,
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
                commentBadgeIds: paragraphs
                    .map((p) => p.id.toStringValue())
                    .toSet(),
              ),
            ),
          );
          await tester.pump();
          expect(
            tester.takeException(),
            isNull,
            reason: 'font=$fontScale system=$systemScale',
          );
          badges += find.byType(CommentBadge).evaluate().length;
        }
        expect(badges, paragraphs.length);
      }
    }
  });
}

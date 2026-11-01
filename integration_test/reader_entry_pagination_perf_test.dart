import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:langhuan/features/bookshelf/widgets/comment_badge.dart';
import 'package:langhuan/features/bookshelf/widgets/page_breaker.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import 'package:langhuan/src/rust/api/types.dart';

/// Entry-stutter probe — NOT a pass/fail layout test.
///
/// Entering the reader paginates every loaded chapter synchronously inside a
/// single build ([ChapterContentManager._pagesFor] → [PageBreaker.computePages]
/// → TextPainter on the UI thread). This probe measures that work on-device
/// with the real system font so the entry cost can be reasoned about:
///
/// * one realistic chapter (~90 paragraphs, ~70% carrying comment badges),
/// * phone and desktop page sizes, reading font scales 1.0/1.5,
/// * badges on/off to expose the [CommentParagraphLayout] multiplier,
/// * a per-paragraph time distribution, because a chunked pagination design
///   can only spread work as finely as a single paragraph's worst case,
/// * a frame-budget simulation: how many frames one chapter needs when each
///   frame gets a bounded pagination slice.
///
/// The structural `expect`s only guard against degenerate output; all
/// measurements are printed via `debugPrint` as `[probe]` lines.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Production pageSize is `MediaQuery size − contentPadding`; 342×772 is a
  // 390×844 phone with the default 24 reading padding on all sides.
  const phonePage = Size(342, 772);
  const desktopPage = Size(1232, 616);

  ParagraphId pid(String s) =>
      ParagraphId(original: OriginalParagraphId.source(s), path: const []);

  int paragraphLength(int i) => i % 7 == 3 ? 14 + i % 22 : 36 + (i * 61) % 236;

  String body(int index, int length) {
    const lines = [
      '陸雲沿着山道往上走的時候，天色已經暗了下來，遠處的燈火一盞盞亮起，像是有人把星星撒在了半山腰。',
      '「你確定要這麼做？」她盯着他看了很久，聲音壓得很低，「這條路走到底，就再也回不了頭了。」',
      '他沉默了片刻，把信紙折好塞回信封，動作很慢，彷彿多停留一秒，就能多留住一點什麼。',
      '夜色漸深，城裏的燈一盞一盞滅了，只剩長街盡頭那盞還亮着，照着空蕩蕩的石板路。',
      '走廊盡頭的燈忽明忽暗，腳步聲輕得幾乎聽不見，像是有人貼着牆根在走。',
      '「不必了。」他說得很平靜，平靜得像是早就知道會有這麼一天。',
      '窗外的雨下了整夜，屋檐的水一滴一滴敲在石階上，節奏單調得讓人發慌。',
      '她把茶盞推到他面前，茶湯映着燭火，晃出一圈細碎的金邊：「喝完這杯，就動身吧。」',
      '山風捲着松濤從谷底涌上來，吹得火把一陣搖晃，影子在岩壁上扭成奇怪的形狀。',
      '他翻過最後一頁賬冊，指尖停在某一處，眉頭慢慢皺了起來，燭芯恰在此時爆了個燈花。',
      '「我問最後一遍，」刀刃貼着咽喉，聲音卻沒有半分波瀾，「人在哪裏。」',
      '天快亮了，霧氣從河面上漫進城來，街角賣早點的攤子剛支起來，蒸籠冒着白氣。',
    ];
    final sb = StringBuffer();
    var step = index;
    while (sb.length < length) {
      sb.write(lines[(index + step) % lines.length]);
      step += 7;
    }
    return sb.toString();
  }

  List<ParagraphContent> buildChapter() => [
    ParagraphContent.title(id: pid('t'), text: '第兩百一十三章 夜行'),
    for (var i = 0; i < 90; i++)
      ParagraphContent.text(
        id: pid('$i'),
        content: body(i, paragraphLength(i)),
        // fanqie-like density: ~70% of paragraphs carry comments.
        commentCount: i % 10 < 7 ? 2 + (i * 17) % 400 : null,
      ),
  ];

  Map<String, Size> badgeSizesOf(
    List<ParagraphContent> paragraphs,
    BuildContext context,
  ) {
    // Mirrors ChapterContentManager._pagesFor: one TextPainter measurement
    // per distinct comment count.
    final byCount = <int, Size>{};
    return {
      for (final paragraph in paragraphs)
        if (paragraph.commentCount case final count? when count > 0)
          paragraph.id.toStringValue(): byCount.putIfAbsent(
            count,
            () => CommentBadge.inlineSize(context, count),
          ),
    };
  }

  testWidgets('probe: computePages cost of one realistic chapter', (
    tester,
  ) async {
    final lines = <String>[];
    void report(String line) {
      debugPrint(line);
      lines.add(line);
    }

    late BuildContext readerContext;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) {
              readerContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    await tester.pump();
    final theme = Theme.of(readerContext);
    final paragraphs = buildChapter();
    report(
      '[probe] mode=${kDebugMode ? 'debug' : kProfileMode ? 'profile' : 'release'} '
      'paragraphs=${paragraphs.length} '
      'badged=${paragraphs.where((p) => (p.commentCount ?? 0) > 0).length} '
      'bodyChars=${paragraphs.fold<int>(0, (a, p) => a + (p is ParagraphContent_Text ? p.content.length : 0))}',
    );

    PageBreaker breakerFor(Size pageSize, double scale) => PageBreaker(
      pageSize: pageSize,
      textStyle: (theme.textTheme.bodyLarge ?? const TextStyle()).copyWith(
        fontSize: (theme.textTheme.bodyLarge?.fontSize ?? 16) * scale,
        height: 1.8,
      ),
      titleStyle: (theme.textTheme.headlineSmall ?? const TextStyle()).copyWith(
        fontSize: (theme.textTheme.headlineSmall?.fontSize ?? 24) * scale,
      ),
      paragraphSpacing: 16,
      imageHeight: pageSize.width * 9 / 16,
      textDirection: Directionality.of(readerContext),
      textScaler: MediaQuery.textScalerOf(readerContext),
      locale: Localizations.localeOf(readerContext),
    );

    // The reader prewarms the badge label style while chapters load; do the
    // same here so the loop below measures steady-state slice cost, with the
    // one-time warmup reported on its own line.
    final warmupWatch = Stopwatch()..start();
    CommentBadge.inlineSize(readerContext, 1);
    warmupWatch.stop();
    report(
      '[probe] badge style warmup (first inlineSize): '
      '${warmupWatch.elapsedMicroseconds}µs',
    );

    // Per-paragraph distribution FIRST, with a cold badge-size cache: it is
    // the finest granularity a chunked pagination can achieve, and therefore
    // the per-frame worst case. Badges resolve lazily through
    // CommentBadge.inlineSize, exactly like the reader's pagination slices,
    // so each first-seen count pays its measurement here too.
    final countOf = <String, int>{
      for (final paragraph in paragraphs)
        if ((paragraph.commentCount ?? 0) > 0)
          paragraph.id.toStringValue(): paragraph.commentCount!,
    };
    for (final scale in [1.0, 1.5]) {
      final breaker = breakerFor(phonePage, scale);
      final times = <int>[];
      for (final paragraph in paragraphs) {
        if (paragraph is! ParagraphContent_Text) continue;
        final watch = Stopwatch()..start();
        final job = breaker.startPagination(
          [paragraph],
          chapterId: 'probe',
          commentBadgeSizeOf: (id) {
            final count = countOf[id];
            return count == null
                ? null
                : CommentBadge.inlineSize(readerContext, count);
          },
        );
        while (!job.step(const Duration(seconds: 10))) {}
        watch.stop();
        times.add(watch.elapsedMicroseconds);
      }
      final sorted = [...times]..sort();
      int at(int percentile) => sorted[(sorted.length - 1) * percentile ~/ 100];
      final total = times.fold<int>(0, (a, b) => a + b);
      report(
        '[probe] per-paragraph µs (phone scale=${scale.toStringAsFixed(1)} '
        'badges=on, lazy sizes): min=${sorted.first} p50=${at(50)} p90=${at(90)} '
        'p95=${at(95)} max=${sorted.last} total=$total µs over ${times.length}',
      );
      for (final budgetMicros in const [4000, 8000]) {
        var chunks = 1;
        var acc = 0;
        for (final micros in times) {
          if (acc + micros > budgetMicros) {
            chunks++;
            acc = micros;
          } else {
            acc += micros;
          }
        }
        report(
          '[probe] chunked at ${budgetMicros ~/ 1000}ms/frame → '
          '$chunks frames for one chapter (${ms(total)} total work)',
        );
      }
    }

    final badgeWatch = Stopwatch()..start();
    final badgeSizes = badgeSizesOf(paragraphs, readerContext);
    badgeWatch.stop();
    report(
      '[probe] badge size map (cache warm from the loop above): '
      '${badgeSizes.length} entries, ${badgeWatch.elapsedMicroseconds}µs',
    );

    var pages = const <PageContent>[];
    for (final config in const [
      ('phone', phonePage, 1.0),
      ('phone', phonePage, 1.5),
      ('desktop', desktopPage, 1.0),
      ('desktop', desktopPage, 1.5),
    ]) {
      final breaker = breakerFor(config.$2, config.$3);
      for (final withBadges in [false, true]) {
        final sizes = withBadges ? badgeSizes : const <String, Size>{};
        var coldMicros = 0;
        final warmMicros = <int>[];
        for (var run = 0; run < 4; run++) {
          final watch = Stopwatch()..start();
          pages = breaker.computePages(
            paragraphs,
            chapterId: 'probe',
            commentBadgeSizes: sizes,
          );
          watch.stop();
          expect(pages, isNotEmpty, reason: 'config=${config.$1}');
          if (run == 0) {
            coldMicros = watch.elapsedMicroseconds;
          } else {
            warmMicros.add(watch.elapsedMicroseconds);
          }
        }
        report(
          '[probe] chapter ${config.$1} scale=${config.$3.toStringAsFixed(1)} '
          'badges=${withBadges ? 'on ' : 'off'} pages=${pages.length} '
          'cold=${ms(coldMicros)} warm=${warmMicros.map(ms).join('/')}',
        );
      }
    }

    // `flutter test -d <device>` does not reliably forward app stdout to the
    // terminal; persist the report so the numbers survive the run.
    try {
      final file = File(
        '${Directory.systemTemp.path}/langhuan_entry_probe.txt',
      );
      await file.writeAsString(lines.join('\n'));
      report('[probe] report written to ${file.path}');
    } catch (error) {
      debugPrint('[probe] report write failed: $error');
    }
  });
}

String ms(int micros) => '${(micros / 1000).toStringAsFixed(1)}ms';

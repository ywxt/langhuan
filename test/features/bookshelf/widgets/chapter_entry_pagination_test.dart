import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:langhuan/features/bookshelf/reader_settings_provider.dart'
    show ReaderPageMode;
import 'package:langhuan/features/bookshelf/widgets/chapter_content_manager.dart';
import 'package:langhuan/features/bookshelf/widgets/reader_controller.dart';
import 'package:langhuan/features/feeds/feed_service.dart'
    show ChapterInfoModel, ParagraphIdStringExt;
import 'package:langhuan/src/rust/api/types.dart';
import 'package:langhuan/l10n/app_localizations.dart';

import '../../feeds/fake_feed_service.dart';

/// Entry behavior of the chunked horizontal pagination.
///
/// Entering the reader loads the anchor's 3-chapter window at once; before
/// chunking, every arrival ran a whole-chapter pagination inside one build,
/// and the window-edge preloader misjudged the still-loading flat list as
/// "at both edges" (fallback index 0) and expanded to five chapters before
/// anything was even paginated. These tests pin the fixed contract:
///
/// * entry fetches only the window chapters around the anchor,
/// * a mid-chapter restore shows the loading mask until the target page
///   exists — the chapter start never flashes first.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Five chapters of ~8 pages each (110 one-line paragraphs at the default
  // test surface), so a mid-chapter anchor sits far from both flat-list
  // edges and any expansion during entry must come from the fixed bug.
  const chapters = [
    ChapterInfoModel(id: 'c1', title: 'Chapter One'),
    ChapterInfoModel(id: 'c2', title: 'Chapter Two'),
    ChapterInfoModel(id: 'c3', title: 'Chapter Three'),
    ChapterInfoModel(id: 'c4', title: 'Chapter Four'),
    ChapterInfoModel(id: 'c5', title: 'Chapter Five'),
  ];

  List<ParagraphContent> bodyOf(String chapterId) => [
    for (var i = 0; i < 110; i++)
      ParagraphContent.text(
        id: ParagraphId(
          original: OriginalParagraphId.source('$chapterId-p$i'),
          path: const [],
        ),
        content: '$chapterId paragraph $i',
      ),
  ];

  /// Service that records every fetched chapter id.
  (FakeFeedService, List<String>) trackingService() {
    final calls = <String>[];
    return (
      FakeFeedService(
        paragraphsHandler:
            (feedId, bookId, chapterId, {forceRefresh = false}) async {
              calls.add(chapterId);
              return bodyOf(chapterId);
            },
      ),
      calls,
    );
  }

  Future<ReaderController> pumpReader(
    WidgetTester tester, {
    required FakeFeedService service,
    void Function(ReaderController)? prepare,
  }) async {
    final controller = ReaderController();
    prepare?.call(controller);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ChapterContentManager(
            feedService: service,
            feedId: 'f1',
            bookId: 'b1',
            chapters: chapters,
            controller: controller,
            pageMode: ReaderPageMode.horizontal,
            onToggleControls: () {},
            fontScale: 1.0,
            lineHeight: 1.5,
            contentPadding: const EdgeInsets.all(16),
            transformerRevision: '',
            // One paragraph per frame: the mask lifecycle becomes
            // deterministic instead of racing a real-time 4ms budget.
            paginationSliceBudget: Duration.zero,
          ),
        ),
      ),
    );
    return controller;
  }

  testWidgets('entry fetches only the window around the anchor', (
    tester,
  ) async {
    final (service, calls) = trackingService();
    await pumpReader(
      tester,
      service: service,
      prepare: (controller) => controller.jumpTo(chapterId: 'c3'),
    );
    await tester.pumpAndSettle();

    // The old entry cascade expanded the window to c1 and c5 before any
    // chapter had paginated; only the anchor's own window may load.
    expect(calls.toSet(), {'c2', 'c3', 'c4'});
    expect(calls.length, 3, reason: 'each window chapter fetched once');
    // The anchor's first page is on screen, not a loading placeholder.
    expect(find.text('c3 paragraph 0').hitTestable(), findsOneWidget);
    expect(find.text('Chapter Three'), findsNothing);
  });

  testWidgets('a mid-chapter restore masks until the target page exists', (
    tester,
  ) async {
    final (service, calls) = trackingService();
    await pumpReader(
      tester,
      service: service,
      prepare: (controller) => controller.jumpTo(
        chapterId: 'c3',
        // Position reports (and therefore stored progress) identify
        // paragraphs by their serialized id, not the bare source id.
        paragraphId: ParagraphId(
          original: const OriginalParagraphId.source('c3-p50'),
          path: const [],
        ).toStringValue(),
      ),
    );

    // Drive past the point where the chapter's first pages have frozen but
    // well before its pagination completes: this is exactly the window in
    // which an unmasked restore would park the reader on the chapter start.
    for (var i = 0; i < 30; i++) {
      await tester.pump();
    }

    // The active chapter shows its loading block while its pages are still
    // being computed; its body stays out of the tree entirely, so the
    // chapter start never flashes before the restore resolves.
    expect(find.text('Chapter Three'), findsOneWidget);
    expect(find.text('c3 paragraph 0'), findsNothing);
    expect(find.text('c3 paragraph 50'), findsNothing);

    await tester.pumpAndSettle();

    // Restored onto the page containing the target paragraph.
    expect(find.text('c3 paragraph 50').hitTestable(), findsOneWidget);
    expect(find.text('c3 paragraph 0').hitTestable(), findsNothing);
    expect(find.text('Chapter Three'), findsNothing);
    expect(calls.toSet(), {'c2', 'c3', 'c4'});
  });
}

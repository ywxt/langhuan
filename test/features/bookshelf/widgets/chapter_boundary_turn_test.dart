import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:langhuan/features/bookshelf/reader_settings_provider.dart'
    show ReaderPageMode;
import 'package:langhuan/features/bookshelf/widgets/chapter_content_manager.dart';
import 'package:langhuan/features/bookshelf/widgets/reader_controller.dart';
import 'package:langhuan/features/feeds/feed_service.dart'
    show ChapterInfoModel;
import 'package:langhuan/src/rust/api/comments.dart';
import 'package:langhuan/src/rust/api/types.dart';
import 'package:langhuan/l10n/app_localizations.dart';

import '../../feeds/fake_feed_service.dart';

/// Boundary turns in horizontal mode.
///
/// Turning into a chapter that is still fetching parks the reader on that
/// chapter's loading placeholder (flat-entry localPageIndex -1). When the
/// chapter then materializes, the active index must resolve onto the
/// chapter's first page — the reload shrink-clamp used to park it on the
/// chapter's last entry instead, which with the chapter-end section on is
/// the comments page.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const chapters = [
    ChapterInfoModel(id: 'c1', title: 'Chapter One'),
    ChapterInfoModel(id: 'c2', title: 'Chapter Two'),
  ];

  // One page per chapter: the flat list is [c1 page, c1 section, c2 page,
  // c2 section] once both chapters are loaded.
  final data = <String, List<ParagraphContent>>{
    'c1': [
      ParagraphContent_Title(
        id: ParagraphId(
          original: const OriginalParagraphId.source('c1-t'),
          path: const [],
        ),
        text: 'Chapter One',
      ),
      ParagraphContent_Text(
        id: ParagraphId(
          original: const OriginalParagraphId.source('c1-b'),
          path: const [],
        ),
        content: 'Body one.',
      ),
    ],
    'c2': [
      ParagraphContent_Title(
        id: ParagraphId(
          original: const OriginalParagraphId.source('c2-t'),
          path: const [],
        ),
        text: 'Chapter Two',
      ),
      ParagraphContent_Text(
        id: ParagraphId(
          original: const OriginalParagraphId.source('c2-b'),
          path: const [],
        ),
        content: 'Body two.',
      ),
    ],
  };

  testWidgets('a turn into a still-loading chapter opens on its first page', (
    tester,
  ) async {
    // c2's fetch stays gated until the reader is parked on its loading
    // placeholder, exactly like a slow network chapter ahead.
    final c2Gate = Completer<void>();
    final service = FakeFeedService(
      paragraphsHandler:
          (feedId, bookId, chapterId, {forceRefresh = false}) async {
            if (chapterId == 'c2') await c2Gate.future;
            return data[chapterId] ?? const [];
          },
      openCommentsPageHandler:
          ({
            required String feedId,
            required String bookId,
            required String chapterId,
            String? paragraphId,
            String? parentId,
            String? cursorJson,
          }) async => commentPageOf(chapterId),
    );

    final controller = ReaderController();
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
            chineseConversion: ChineseConversionMode.none,
            showChapterComments: true,
            // One paragraph per frame: the materialization becomes
            // deterministic instead of racing a real-time budget.
            paginationSliceBudget: Duration.zero,
          ),
        ),
      ),
    );

    // Entry: c1 fetches and paginates; c2's slot stays a loading
    // placeholder. Its spinner animates forever, so every pump below is
    // bounded — pumpAndSettle can never settle here.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Body one.').hitTestable(), findsOneWidget);

    // Turn onto c1's chapter-end section, then into c2's placeholder. The
    // animation's ticker establishes its time origin on the first frame
    // after the tap, so each turn pumps one frame before advancing the
    // clock past the 300ms settle.
    for (var turn = 0; turn < 2; turn++) {
      await tester.tapAt(const Offset(760, 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Body two.'), findsNothing);
    expect(find.text('Loading…'), findsOneWidget);

    // The chapter arrives; the reader must open on its first text page,
    // not be clamped onto the chapter-end comments entry.
    c2Gate.complete();
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('Body two.').hitTestable(), findsOneWidget);
    expect(find.text('Comment for c2').hitTestable(), findsNothing);
  });
}

/// One comment per chapter, so each section carries addressable content.
CommentPage commentPageOf(String chapterId) => CommentPage(
  items: [
    CommentItem(
      id: '$chapterId-k1',
      author: CommentAuthor(name: 'Reader'),
      text: 'Comment for $chapterId',
      replies: const CommentReplies(totalCount: 1),
    ),
  ],
  nextCursorJson: null,
  totalCount: 1,
);

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/book_detail_page.dart';
import 'package:langhuan/features/bookshelf/book_providers.dart';
import 'package:langhuan/features/bookshelf/bookshelf_provider.dart';
import 'package:langhuan/features/bookshelf/reading_progress_provider.dart';
import 'package:langhuan/features/bookshelf/widgets/chapter_cache_indicator.dart';
import 'package:langhuan/features/bookshelf/widgets/reader_sheets.dart';
import 'package:langhuan/features/feeds/feed_providers.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import 'package:langhuan/rust_init.dart';
import 'package:langhuan/shared/chapter_cache_changes.dart';

import '../feeds/fake_feed_service.dart';

const _chapters = [
  ChapterInfoModel(id: 'one', title: 'Chapter one'),
  ChapterInfoModel(id: 'two', title: 'Chapter two'),
];

class _Info extends BookInfoNotifier {
  @override
  BookInfoState build() => const BookInfoState(
    feedId: 'f',
    bookId: 'b',
    book: BookInfoModel(id: 'b', title: 'Book', author: 'Author'),
  );
  @override
  Future<void> load({required String feedId, required String bookId}) async {}
}

class _Chapters extends ChaptersNotifier {
  @override
  ChaptersState build() =>
      const ChaptersState(feedId: 'f', bookId: 'b', items: _chapters);
  @override
  Future<void> load({required String feedId, required String bookId}) async {}
}

class _Shelf extends BookshelfNotifier {
  @override
  BookshelfState build() => const BookshelfState();
}

class _Progress extends ReadingProgressNotifier {
  @override
  ReadingProgressState build() => const ReadingProgressState(
    feedId: 'f',
    bookId: 'b',
    activeChapterId: 'one',
    progress: ReadingProgressModel(
      feedId: 'f',
      bookId: 'b',
      chapterId: 'one',
      paragraphId: '',
      updatedAtMs: 1,
    ),
  );
  @override
  Future<void> load({
    required String feedId,
    required String bookId,
    required String fallbackChapterId,
    String fallbackParagraphId = '',
  }) async {}
}

bool? _cached(WidgetTester tester, String title) => tester
    .widget<ChapterCacheIndicator>(
      find.descendant(
        of: find.widgetWithText(ListTile, title),
        matching: find.byType(ChapterCacheIndicator),
      ),
    )
    .cached;

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('detail chapters show cached and current states, $brightness', (
      tester,
    ) async {
      var ids = ['one'];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDataDirectorySetProvider.overrideWith(
              (ref) async => const AppDataDirectoryResult(feedCount: 0),
            ),
            feedServiceProvider.overrideWithValue(
              FakeFeedService(
                cachedChapterIdsHandler: (feed, book) async => ids,
              ),
            ),
            bookInfoProvider.overrideWith(_Info.new),
            chaptersProvider.overrideWith(_Chapters.new),
            bookshelfProvider.overrideWith(_Shelf.new),
            readingProgressProvider.overrideWith(_Progress.new),
          ],
          child: MaterialApp(
            theme: ThemeData(brightness: brightness),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const BookDetailPage(feedId: 'f', bookId: 'b'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(_cached(tester, 'Chapter one'), isTrue);
      expect(_cached(tester, 'Chapter two'), isFalse);
      expect(find.byTooltip('Cached'), findsOneWidget);
      expect(find.byTooltip('Not cached'), findsOneWidget);
      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Chapter one'),
          matching: find.byIcon(Icons.bookmark),
        ),
        findsOneWidget,
      );
      ids = ['two'];
      notifyChapterCacheChanged(feedId: 'f', bookId: 'b');
      await tester.pumpAndSettle();
      expect(_cached(tester, 'Chapter one'), isFalse);
      expect(_cached(tester, 'Chapter two'), isTrue);
      ids = [];
      notifyChapterCacheChanged();
      await tester.pumpAndSettle();
      expect(_cached(tester, 'Chapter one'), isFalse);
      expect(_cached(tester, 'Chapter two'), isFalse);
      expect(
        tester
            .widget<ListTile>(find.widgetWithText(ListTile, 'Chapter two'))
            .onTap,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('reader TOC retains badges through filtering and live updates', (
    tester,
  ) async {
    var ids = ['one'];
    final jumps = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDataDirectorySetProvider.overrideWith(
            (ref) async => const AppDataDirectoryResult(feedCount: 0),
          ),
          feedServiceProvider.overrideWithValue(
            FakeFeedService(cachedChapterIdsHandler: (feed, book) async => ids),
          ),
          readingProgressProvider.overrideWith(_Progress.new),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => showReaderTocSheet(
                  context: context,
                  ref: ref,
                  feedId: 'f',
                  bookId: 'b',
                  chapters: _chapters,
                  onJumpToChapter: jumps.add,
                ),
                child: const Text('Open TOC'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open TOC'));
    await tester.pumpAndSettle();
    expect(_cached(tester, 'Chapter one'), isTrue);
    expect(_cached(tester, 'Chapter two'), isFalse);
    expect(
      tester
          .widget<ListTile>(find.widgetWithText(ListTile, 'Chapter one'))
          .selected,
      isTrue,
    );
    await tester.enterText(find.byType(TextField), 'two');
    await tester.pumpAndSettle();
    expect(find.text('Chapter one'), findsNothing);
    expect(_cached(tester, 'Chapter two'), isFalse);
    ids = ['one', 'two'];
    notifyChapterCacheChanged(feedId: 'f', bookId: 'b');
    await tester.pumpAndSettle();
    expect(_cached(tester, 'Chapter two'), isTrue);
    await tester.tap(find.text('Chapter two'));
    await tester.pumpAndSettle();
    expect(jumps, ['two']);
    expect(tester.takeException(), isNull);
  });
}

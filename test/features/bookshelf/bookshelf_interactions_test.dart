import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:langhuan/features/bookshelf/book_detail_page.dart';
import 'package:langhuan/features/bookshelf/book_providers.dart';
import 'package:langhuan/features/bookshelf/bookshelf_page.dart';
import 'package:langhuan/features/bookshelf/bookshelf_provider.dart';
import 'package:langhuan/features/bookshelf/reading_progress_provider.dart';
import 'package:langhuan/features/bookshelf/widgets/book_cover.dart';
import 'package:langhuan/features/bookshelf/widgets/book_cover_hero.dart';
import 'package:langhuan/features/bookshelf/widgets/search_result_card.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import 'package:langhuan/rust_init.dart';
import 'package:langhuan/shared/widgets/cover_image.dart';

const _book = BookshelfItemModel(
  feedId: 'feed-1',
  sourceBookId: 'book-1',
  title: 'Book one',
  author: 'Author one',
  addedAtUnixMs: 1,
);

class _TestBookshelfNotifier extends BookshelfNotifier {
  int removeCalls = 0;

  @override
  BookshelfState build() => const BookshelfState(items: [_book]);

  @override
  Future<BookshelfOperationOutcome> remove({
    required String feedId,
    required String sourceBookId,
  }) async {
    removeCalls++;
    return const BookshelfOperationOutcomeRemoved();
  }
}

class _IdleBookInfoNotifier extends BookInfoNotifier {
  @override
  BookInfoState build() => const BookInfoState();

  @override
  Future<void> load({required String feedId, required String bookId}) async {}
}

class _LoadedBookInfoNotifier extends _IdleBookInfoNotifier {
  @override
  BookInfoState build() => const BookInfoState(
    feedId: 'feed-1',
    bookId: 'book-1',
    book: BookInfoModel(id: 'book-1', title: 'Book one', author: 'Author one'),
  );
}

class _IdleChaptersNotifier extends ChaptersNotifier {
  @override
  ChaptersState build() => const ChaptersState();

  @override
  Future<void> load({required String feedId, required String bookId}) async {}
}

class _IdleProgressNotifier extends ReadingProgressNotifier {
  @override
  ReadingProgressState build() => const ReadingProgressState();

  @override
  Future<void> load({
    required String feedId,
    required String bookId,
    required String fallbackChapterId,
    String fallbackParagraphId = '',
  }) async {}
}

Widget _testApp(GoRouter router) {
  return ProviderScope(
    overrides: [
      bookshelfProvider.overrideWith(_TestBookshelfNotifier.new),
      coverProvider.overrideWith((ref, key) async => null),
    ],
    child: MaterialApp.router(
      routerConfig: router,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
    ),
  );
}

GoRouter _router() {
  return GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const BookshelfPage()),
      GoRoute(
        path: '/read',
        name: 'bookshelf-reader',
        builder: (_, state) => Text(
          'Reader ${state.uri.queryParameters['bookId']}',
          textDirection: TextDirection.ltr,
        ),
      ),
      GoRoute(
        path: '/detail',
        name: 'bookshelf-book-detail',
        builder: (_, _) =>
            const Text('Book details', textDirection: TextDirection.ltr),
      ),
      GoRoute(
        path: '/search',
        name: 'bookshelf-search',
        builder: (_, _) => const SizedBox(),
      ),
    ],
  );
}

void main() {
  testWidgets('tapping a bookshelf book opens the reader', (tester) async {
    final router = _router();
    addTearDown(router.dispose);
    await tester.pumpWidget(_testApp(router));
    await tester.pumpAndSettle();

    await tester.tap(find.text(_book.title));
    await tester.pumpAndSettle();

    expect(find.text('Reader book-1'), findsOneWidget);
  });

  testWidgets('long-pressing a bookshelf book shows management actions', (
    tester,
  ) async {
    final router = _router();
    addTearDown(router.dispose);
    await tester.pumpWidget(_testApp(router));
    await tester.pumpAndSettle();

    await tester.longPress(find.text(_book.title));
    await tester.pumpAndSettle();

    expect(find.text('Book Details'), findsOneWidget);
    expect(find.text('Delete from Bookshelf'), findsOneWidget);
  });

  testWidgets('delete action confirms before removing the book', (
    tester,
  ) async {
    final router = _router();
    addTearDown(router.dispose);
    await tester.pumpWidget(_testApp(router));
    await tester.pumpAndSettle();

    final element = tester.element(find.byType(BookshelfPage));
    final container = ProviderScope.containerOf(element);
    final notifier =
        container.read(bookshelfProvider.notifier) as _TestBookshelfNotifier;

    await tester.longPress(find.text(_book.title));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete from Bookshelf'));
    await tester.pumpAndSettle();

    expect(find.text('Remove "Book one" from your bookshelf?'), findsOneWidget);
    expect(notifier.removeCalls, 0);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(notifier.removeCalls, 1);
    expect(find.text('Removed from local bookshelf'), findsOneWidget);
  });

  testWidgets('search result cover exposes the shared book Hero tag', (
    tester,
  ) async {
    final coverTag = bookCoverHeroTag('feed-1', 'book-1');
    final titleTag = bookTitleHeroTag('feed-1', 'book-1');
    final authorTag = bookAuthorHeroTag('feed-1', 'book-1');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchResultCard(
            item: const SearchResultModel(
              id: 'book-1',
              title: 'Book one',
              author: 'Author one',
            ),
            coverHeroTag: coverTag,
            titleHeroTag: titleTag,
            authorHeroTag: authorTag,
          ),
        ),
      ),
    );

    Finder heroWithTag(Object tag) =>
        find.byWidgetPredicate((widget) => widget is Hero && widget.tag == tag);

    expect(heroWithTag(coverTag), findsOneWidget);
    expect(heroWithTag(titleTag), findsOneWidget);
    expect(heroWithTag(authorTag), findsOneWidget);
  });

  testWidgets('search cover decodes once at the detail Hero size', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SearchResultCard(
            item: SearchResultModel(
              id: 'book-1',
              title: 'Book one',
              author: 'Author one',
              coverUrl: '/missing-cover.jpg',
            ),
          ),
        ),
      ),
    );

    final cover = tester.widget<CoverImage>(find.byType(CoverImage));
    expect(cover.width, 48);
    expect(cover.height, 64);
    expect(cover.decodeWidth, 120);
    expect(cover.decodeHeight, 160);
  });

  testWidgets('uncached detail cover starts at the final horizontal center', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDataDirectorySetProvider.overrideWith(
            (ref) => Completer<AppDataDirectoryResult>().future,
          ),
          bookshelfProvider.overrideWith(_TestBookshelfNotifier.new),
          bookInfoProvider.overrideWith(_IdleBookInfoNotifier.new),
          chaptersProvider.overrideWith(_IdleChaptersNotifier.new),
          readingProgressProvider.overrideWith(_IdleProgressNotifier.new),
        ],
        child: const MaterialApp(
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: BookDetailPage(
            feedId: 'feed-1',
            bookId: 'book-1',
            initialBook: BookDetailRouteExtra(
              coverUrl: '/missing-cover.jpg',
              title: 'Book one',
              author: 'Author one',
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final scaffoldRect = tester.getRect(find.byType(Scaffold));
    final coverRect = tester.getRect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Hero &&
            widget.tag == bookCoverHeroTag('feed-1', 'book-1'),
      ),
    );
    expect(coverRect.center.dx, closeTo(scaffoldRect.center.dx, 0.1));
  });

  testWidgets('detail title and author are centered', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDataDirectorySetProvider.overrideWith(
            (ref) => Completer<AppDataDirectoryResult>().future,
          ),
          bookshelfProvider.overrideWith(_TestBookshelfNotifier.new),
          bookInfoProvider.overrideWith(_LoadedBookInfoNotifier.new),
          chaptersProvider.overrideWith(_IdleChaptersNotifier.new),
          readingProgressProvider.overrideWith(_IdleProgressNotifier.new),
          coverProvider.overrideWith((ref, key) async => null),
        ],
        child: const MaterialApp(
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: BookDetailPage(feedId: 'feed-1', bookId: 'book-1'),
        ),
      ),
    );
    await tester.pump();

    expect(
      tester.widget<Text>(find.text('Book one')).textAlign,
      TextAlign.center,
    );
    expect(
      tester.widget<Text>(find.text('Author one')).textAlign,
      TextAlign.center,
    );
  });
}

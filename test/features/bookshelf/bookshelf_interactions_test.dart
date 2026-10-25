import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:langhuan/features/bookshelf/bookshelf_page.dart';
import 'package:langhuan/features/bookshelf/bookshelf_provider.dart';
import 'package:langhuan/features/bookshelf/widgets/book_cover.dart';
import 'package:langhuan/features/bookshelf/widgets/book_cover_hero.dart';
import 'package:langhuan/features/bookshelf/widgets/search_result_card.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/l10n/app_localizations.dart';
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
    final tag = bookCoverHeroTag('feed-1', 'book-1');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchResultCard(
            item: const SearchResultModel(
              id: 'book-1',
              title: 'Book one',
              author: 'Author one',
            ),
            coverHeroTag: tag,
          ),
        ),
      ),
    );

    expect(
      find.byWidgetPredicate((widget) => widget is Hero && widget.tag == tag),
      findsOneWidget,
    );
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
}

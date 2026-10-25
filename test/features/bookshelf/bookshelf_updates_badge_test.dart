import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:langhuan/features/bookshelf/bookshelf_page.dart';
import 'package:langhuan/features/bookshelf/bookshelf_operation.dart';
import 'package:langhuan/features/bookshelf/bookshelf_provider.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import 'package:langhuan/shared/widgets/loading.dart';
import 'package:langhuan/features/bookshelf/widgets/book_cover.dart';

const _book = BookshelfItemModel(
  feedId: 'feed-1',
  sourceBookId: 'book-1',
  title: 'Book one',
  author: 'Author one',
  addedAtUnixMs: 2,
  progressCurrentChapter: 2,
  progressTotalChapters: 5,
  progressCurrentParagraph: 4,
  progressTotalParagraphs: 10,
  feedEnabled: false,
);

const _otherBook = BookshelfItemModel(
  feedId: 'feed-1',
  sourceBookId: 'book-2',
  title: 'Book two',
  author: 'Author two',
  addedAtUnixMs: 1,
);

class _TestBookshelfNotifier extends BookshelfNotifier {
  @override
  BookshelfState build() => const BookshelfState(items: [_book, _otherBook]);

  @override
  Future<BookshelfRemoveResult> remove({
    required String feedId,
    required String sourceBookId,
  }) async {
    return BookshelfRemoveResult.removed;
  }
}

/// Update-check notifier whose state can be seeded for rendering and flipped
/// mid-test via [emit] to drive the page's one-shot feedback listeners.
class _TestUpdatesNotifier extends BookshelfUpdatesNotifier {
  _TestUpdatesNotifier([this.initial = const BookshelfUpdatesState()]);

  final BookshelfUpdatesState initial;

  @override
  BookshelfUpdatesState build() => initial;

  void emit(BookshelfUpdatesState next) => state = next;
}

Widget _testApp(GoRouter router, _TestUpdatesNotifier updates) {
  return ProviderScope(
    overrides: [
      bookshelfProvider.overrideWith(_TestBookshelfNotifier.new),
      bookshelfUpdatesProvider.overrideWith(() => updates),
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
        path: '/detail',
        name: 'bookshelf-book-detail',
        builder: (_, _) =>
            const Text('Book details', textDirection: TextDirection.ltr),
      ),
    ],
  );
}

void main() {
  testWidgets(
    'cached chapter and paragraph progress is shown on the book card',
    (tester) async {
      final router = _router();
      addTearDown(router.dispose);
      await tester.pumpWidget(_testApp(router, _TestUpdatesNotifier()));
      await tester.pumpAndSettle();

      expect(find.text('Chapter 2 of 5 · 28%'), findsOneWidget);
      final progress = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(progress.value, closeTo(0.28, 0.001));
    },
  );

  testWidgets('paused feed is marked without hiding its bookshelf book', (
    tester,
  ) async {
    final router = _router();
    addTearDown(router.dispose);
    await tester.pumpWidget(_testApp(router, _TestUpdatesNotifier()));
    await tester.pumpAndSettle();

    expect(find.text(_book.title), findsOneWidget);
    expect(
      find.byTooltip(
        'This feed is paused. The saved book remains readable, but update checks are skipped.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('update badge shows the new chapter count with semantics', (
    tester,
  ) async {
    final router = _router();
    addTearDown(router.dispose);
    final updates = _TestUpdatesNotifier(
      const BookshelfUpdatesState(newChaptersByBook: {'feed-1:book-1': 3}),
    );
    await tester.pumpWidget(_testApp(router, updates));
    await tester.pumpAndSettle();

    expect(find.text('3'), findsOneWidget);

    final handle = tester.ensureSemantics();
    expect(find.bySemanticsLabel(RegExp('3 new chapters')), findsOneWidget);
    handle.dispose();

    // The badge belongs to the updated book's row, not the other book's.
    final row = find
        .ancestor(of: find.text('3'), matching: find.byType(ListTile))
        .first;
    expect(
      find.descendant(of: row, matching: find.text(_book.title)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.text(_otherBook.title)),
      findsNothing,
    );
  });

  testWidgets('books without new chapters carry no badge', (tester) async {
    final router = _router();
    addTearDown(router.dispose);
    final updates = _TestUpdatesNotifier();
    await tester.pumpWidget(_testApp(router, updates));
    await tester.pumpAndSettle();

    final handle = tester.ensureSemantics();
    expect(find.bySemanticsLabel(RegExp('new chapters')), findsNothing);
    handle.dispose();
  });

  testWidgets('checking state renders no action, only pull-to-refresh', (
    tester,
  ) async {
    final router = _router();
    addTearDown(router.dispose);
    final updates = _TestUpdatesNotifier(
      const BookshelfUpdatesState(isChecking: true),
    );
    await tester.pumpWidget(_testApp(router, updates));
    await tester.pump();

    // The title row carries neither a refresh button nor a spinner; the
    // RefreshIndicator owns the checking feedback while the gesture is
    // active.
    expect(find.byTooltip('Check for updates'), findsNothing);
    expect(find.byType(LanghuanSpinner), findsNothing);
    expect(find.byType(RefreshIndicator), findsOneWidget);
  });

  testWidgets('a finished check with per-book failures reports a snackbar', (
    tester,
  ) async {
    final router = _router();
    addTearDown(router.dispose);
    final updates = _TestUpdatesNotifier();
    await tester.pumpWidget(_testApp(router, updates));
    await tester.pumpAndSettle();

    updates.emit(const BookshelfUpdatesState(isChecking: true));
    await tester.pump();

    updates.emit(
      const BookshelfUpdatesState(
        isChecking: false,
        failedBooks: {'feed-1:book-1': 'source unavailable'},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Failed to check 1 books'), findsOneWidget);

    // Failed books never get a badge.
    final handle = tester.ensureSemantics();
    expect(find.bySemanticsLabel(RegExp('new chapters')), findsNothing);
    handle.dispose();
  });
}

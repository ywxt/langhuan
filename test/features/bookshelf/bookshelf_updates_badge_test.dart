import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
  progressChapterTitle: 'Frostfall',
  feedEnabled: false,
);

const _otherBook = BookshelfItemModel(
  feedId: 'feed-1',
  sourceBookId: 'book-2',
  title: 'Book two',
  author: 'Author two',
  addedAtUnixMs: 1,
  progressCurrentChapter: 1,
  progressTotalChapters: 4,
);

/// Chapter title long enough to overflow any realistic card width.
const _longTitleBook = BookshelfItemModel(
  feedId: 'feed-1',
  sourceBookId: 'book-3',
  title: 'Book three',
  author: 'Author three',
  addedAtUnixMs: 3,
  progressCurrentChapter: 9,
  progressTotalChapters: 10,
  progressCurrentParagraph: 1,
  progressTotalParagraphs: 2,
  progressChapterTitle:
      'A Chapter Title So Remarkably Long That It Cannot Possibly Fit On A Single Card Line',
  feedEnabled: false,
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

/// Bookshelf variant that lists only the long-title book.
class _LongTitleBookshelfNotifier extends _TestBookshelfNotifier {
  @override
  BookshelfState build() => const BookshelfState(items: [_longTitleBook]);
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

Widget _testApp(
  GoRouter router,
  _TestUpdatesNotifier updates, {
  BookshelfNotifier Function()? bookshelf,
}) {
  return ProviderScope(
    overrides: [
      bookshelfProvider.overrideWith(bookshelf ?? _TestBookshelfNotifier.new),
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

      // The progress line is led by the chapter title, and no bar is
      // rendered on the card.
      expect(find.text('Frostfall'), findsOneWidget);
      expect(find.text(' · 28%'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    },
  );

  testWidgets(
    'progress without a cached chapter title falls back to chapter numbers',
    (tester) async {
      final router = _router();
      addTearDown(router.dispose);
      await tester.pumpWidget(_testApp(router, _TestUpdatesNotifier()));
      await tester.pumpAndSettle();

      expect(find.text('Chapter 1 of 4 · 25%'), findsOneWidget);
    },
  );

  testWidgets(
    'an overlong chapter title ellipsises without hiding the percent',
    (tester) async {
      final router = _router();
      addTearDown(router.dispose);
      await tester.pumpWidget(
        _testApp(
          router,
          _TestUpdatesNotifier(),
          bookshelf: _LongTitleBookshelfNotifier.new,
        ),
      );
      await tester.pumpAndSettle();

      // The percent keeps its own slot at the end of the line and is
      // never crowded out, whatever the title length.
      expect(find.text(' · 85%'), findsOneWidget);

      // The title itself is truncated with an ellipsis: it renders
      // narrower than its full text lays out.
      final paragraph = tester.renderObject<RenderParagraph>(
        find.text(_longTitleBook.progressChapterTitle!),
      );
      final unconstrained = TextPainter(
        text: paragraph.text,
        textDirection: TextDirection.ltr,
      )..layout();
      expect(paragraph.size.width, lessThan(unconstrained.width));
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

  testWidgets('checking state disables refresh and swaps in a spinner', (
    tester,
  ) async {
    final router = _router();
    addTearDown(router.dispose);
    final updates = _TestUpdatesNotifier(
      const BookshelfUpdatesState(isChecking: true),
    );
    await tester.pumpWidget(_testApp(router, updates));
    await tester.pump();

    // The title row's refresh button carries the checking feedback itself:
    // disabled, with its icon swapped for an inline spinner until the check
    // finishes. Pull-to-refresh stays available through the
    // RefreshIndicator for the duration.
    final refreshButton = find.byWidgetPredicate(
      (widget) =>
          widget is IconButton &&
          widget.tooltip == 'Refresh bookshelf and check for updates',
    );
    expect(refreshButton, findsOneWidget);
    expect(tester.widget<IconButton>(refreshButton).onPressed, isNull);
    expect(find.byType(LanghuanSpinner), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsNothing);
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

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:langhuan/features/bookshelf/search_history_provider.dart';
import 'package:langhuan/features/bookshelf/search_page.dart';
import 'package:langhuan/features/feeds/feed_providers.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/features/feeds/search_provider.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import 'package:langhuan/rust_init.dart';
import 'package:langhuan/src/rust/api/types.dart';

const _feedA = FeedMetaItem(
  id: 'feed-a',
  name: 'Source A',
  version: '1',
  enabled: true,
  accessDomains: [],
);
const _feedB = FeedMetaItem(
  id: 'feed-b',
  name: 'Source B',
  version: '1',
  enabled: true,
  accessDomains: [],
);

const _resultA1 = SearchResultModel(
  id: 'a-1',
  title: 'Book A1',
  author: 'Author A1',
);

const _resultB1 = SearchResultModel(
  id: 'b-1',
  title: 'Book B1',
  author: 'Author B1',
);

class _TestFeedListNotifier extends FeedListNotifier {
  @override
  FeedListState build() => const FeedListState(items: [_feedA, _feedB]);
}

class _TestSearchNotifier extends SearchNotifier {
  _TestSearchNotifier([this.initial = const SearchState()]);

  final SearchState initial;

  @override
  SearchState build() => initial;
}

class _TrackingSearchNotifier extends _TestSearchNotifier {
  _TrackingSearchNotifier(super.initial);

  int disposeCalls = 0;
  int loadMoreCalls = 0;

  @override
  SearchState build() {
    ref.onDispose(() => disposeCalls++);
    return initial;
  }

  @override
  Future<void> loadMore() async {
    loadMoreCalls++;
  }
}

class _HistorySearchNotifier extends _TestSearchNotifier {
  String? searchedKeyword;

  @override
  Future<void> searchAll({required String keyword}) async {
    searchedKeyword = keyword;
    state = SearchState(keyword: keyword, hasMore: false);
  }
}

Widget _testApp(
  GoRouter router,
  SearchState searchState, {
  SearchNotifier? searchNotifier,
}) {
  return ProviderScope(
    overrides: [
      feedListProvider.overrideWith(_TestFeedListNotifier.new),
      searchProvider.overrideWith(
        () => searchNotifier ?? _TestSearchNotifier(searchState),
      ),
      appDataDirectorySetProvider.overrideWith(
        (ref) async => const AppDataDirectoryResult(feedCount: 2),
      ),
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
      GoRoute(path: '/', builder: (_, _) => const SearchPage()),
      GoRoute(
        path: '/auth',
        name: 'feed-auth',
        builder: (_, _) =>
            const Text('Feed auth', textDirection: TextDirection.ltr),
      ),
      GoRoute(
        path: '/detail',
        builder: (_, _) =>
            const Text('Detail', textDirection: TextDirection.ltr),
      ),
      GoRoute(
        path: '/reader',
        builder: (_, _) =>
            const Text('Reader', textDirection: TextDirection.ltr),
      ),
      GoRoute(
        path: '/other',
        builder: (_, _) =>
            const Text('Other', textDirection: TextDirection.ltr),
      ),
    ],
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'saved history can be searched again and records new submissions',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        SearchHistoryNotifier.storageKey: ['saved term', 'older term'],
      });
      final router = _router();
      addTearDown(router.dispose);
      final search = _HistorySearchNotifier();
      await tester.pumpWidget(
        _testApp(router, const SearchState(), searchNotifier: search),
      );
      await tester.pumpAndSettle();
      expect(find.text('Search history'), findsOneWidget);
      await tester.tap(find.widgetWithText(InputChip, 'saved term'));
      await tester.pumpAndSettle();
      expect(search.searchedKeyword, 'saved term');
      expect(
        tester.widget<SearchBar>(find.byType(SearchBar)).controller!.text,
        'saved term',
      );
      await tester.tap(find.byTooltip('Clear'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(InputChip, 'older term'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, ' new term ');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(search.searchedKeyword, 'new term');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(SearchHistoryNotifier.storageKey), [
        'new term',
        'saved term',
        'older term',
      ]);
    },
  );

  testWidgets('history entries can be deleted individually or cleared', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      SearchHistoryNotifier.storageKey: ['first', 'second'],
    });
    final router = _router();
    addTearDown(router.dispose);
    await tester.pumpWidget(_testApp(router, const SearchState()));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(InputChip, 'second'),
        matching: find.byTooltip('Remove from history'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, 'second'), findsNothing);
    expect(find.widgetWithText(InputChip, 'first'), findsOneWidget);
    await tester.tap(find.text('Clear history'));
    await tester.pumpAndSettle();
    expect(find.byType(InputChip), findsNothing);
    expect(find.text('Enter a keyword to start searching'), findsOneWidget);
  });

  testWidgets('leaving search clears its results and pull cursor', (
    tester,
  ) async {
    final state = SearchState(
      keyword: 'kw',
      hasMore: true,
      groups: [
        SearchFeedGroup(
          feedId: 'feed-a',
          feedName: 'Source A',
          items: [
            _resultA1,
            for (var i = 2; i <= 24; i++)
              SearchResultModel(
                id: 'a-$i',
                title: 'Book A$i',
                author: 'Author A$i',
              ),
          ],
        ),
      ],
    );
    final notifier = _TrackingSearchNotifier(state);
    final router = _router();
    addTearDown(router.dispose);
    await tester.pumpWidget(_testApp(router, state, searchNotifier: notifier));
    await tester.pumpAndSettle();

    // Detail and reader are stacked above search, so unwinding both routes
    // must keep the exact result page without pulling another search page.
    router.push('/detail');
    await tester.pumpAndSettle();
    router.push('/reader');
    await tester.pumpAndSettle();
    expect(notifier.disposeCalls, 0);
    router.pop();
    await tester.pumpAndSettle();
    expect(find.text('Detail'), findsOneWidget);
    router.pop();
    await tester.pumpAndSettle();
    expect(find.text('Book A1'), findsOneWidget);
    expect(
      notifier.loadMoreCalls,
      0,
      reason: 'restoring a nested route is not a pagination gesture',
    );

    final resultsList = find.byWidgetPredicate(
      (widget) => widget is ListView && widget.scrollDirection == Axis.vertical,
    );
    await tester.drag(resultsList, const Offset(0, -5000));
    await tester.pump();
    expect(notifier.loadMoreCalls, 1);

    // Leaving search itself disposes the route and resets the search run.
    router.go('/other');
    await tester.pumpAndSettle();
    expect(notifier.disposeCalls, 1);
  });

  testWidgets('the All chip leads the selector and is selected by default', (
    tester,
  ) async {
    final router = _router();
    addTearDown(router.dispose);
    await tester.pumpWidget(_testApp(router, const SearchState()));
    await tester.pumpAndSettle();

    expect(find.text('All'), findsOneWidget);

    // Selected by default: the aggregated hint is shown.
    expect(find.text('Search across all feeds…'), findsOneWidget);

    // Tapping a single source switches the hint and the selection.
    await tester.tap(find.text('Source B'));
    await tester.pumpAndSettle();
    expect(find.text('Search in Source B…'), findsOneWidget);

    // And back to All.
    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    expect(find.text('Search across all feeds…'), findsOneWidget);
  });

  testWidgets('aggregated results render grouped by source', (tester) async {
    final router = _router();
    addTearDown(router.dispose);
    await tester.pumpWidget(
      _testApp(
        router,
        const SearchState(
          keyword: 'kw',
          hasMore: false,
          groups: [
            SearchFeedGroup(
              feedId: 'feed-a',
              feedName: 'Source A',
              items: [_resultA1],
            ),
            SearchFeedGroup(
              feedId: 'feed-b',
              feedName: 'Source B',
              items: [_resultB1],
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    // One header per source (plus its selector chip), in arrival order.
    expect(find.text('Source A'), findsNWidgets(2));
    expect(find.text('Source B'), findsNWidgets(2));

    // Both sources' books are on screen.
    expect(find.text('Book A1'), findsOneWidget);
    expect(find.text('Book B1'), findsOneWidget);
  });

  testWidgets('a failed source shows its own error, results stay visible', (
    tester,
  ) async {
    final router = _router();
    addTearDown(router.dispose);
    await tester.pumpWidget(
      _testApp(
        router,
        const SearchState(
          keyword: 'kw',
          hasMore: false,
          groups: [
            SearchFeedGroup(
              feedId: 'feed-a',
              feedName: 'Source A',
              items: [_resultA1],
            ),
            SearchFeedGroup(
              feedId: 'feed-b',
              feedName: 'Source B',
              error: 'source unavailable',
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The failed source reports inline instead of failing the whole search.
    expect(find.text('Failed to search Source B'), findsOneWidget);
    expect(find.textContaining('source unavailable'), findsOneWidget);

    // The healthy source's results are unaffected.
    expect(find.text('Book A1'), findsOneWidget);
  });

  testWidgets('a single-source search keeps its flat layout', (tester) async {
    final router = _router();
    addTearDown(router.dispose);
    await tester.pumpWidget(
      _testApp(
        router,
        const SearchState(
          keyword: 'kw',
          hasMore: false,
          groups: [
            SearchFeedGroup(
              feedId: 'feed-a',
              feedName: 'Source A',
              items: [_resultA1],
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    // No section header for a single group — only the selector chip
    // mentions the source.
    expect(find.text('Source A'), findsOneWidget);
    expect(find.text('Book A1'), findsOneWidget);
  });
}

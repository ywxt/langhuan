import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:langhuan/features/bookshelf/search_page.dart';
import 'package:langhuan/features/feeds/feed_providers.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/features/feeds/search_provider.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import 'package:langhuan/rust_init.dart';
import 'package:langhuan/src/rust/api/types.dart';

const _feedA = FeedMetaItem(id: 'feed-a', name: 'Source A', version: '1');
const _feedB = FeedMetaItem(id: 'feed-b', name: 'Source B', version: '1');

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

Widget _testApp(GoRouter router, SearchState searchState) {
  return ProviderScope(
    overrides: [
      feedListProvider.overrideWith(_TestFeedListNotifier.new),
      searchProvider.overrideWith(() => _TestSearchNotifier(searchState)),
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
    ],
  );
}

void main() {
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

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:langhuan/features/feeds/feed_providers.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/features/feeds/widgets/feed_card.dart';
import 'package:langhuan/shared/widgets/configuration_list_card.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import 'package:langhuan/rust_init.dart';
import 'package:langhuan/src/rust/api/types.dart';

import '../fake_feed_service.dart';

const _feedA = FeedMetaItem(
  id: 'feed-a',
  name: 'Source A',
  version: '1',
  enabled: true,
  sourceUrl: 'https://example.com/source-a.js',
  baseUrl: 'https://example.com',
  accessDomains: ['example.com', 'cdn.example.com'],
  description: 'A fixture source for tests.',
);

const _feedAPaused = FeedMetaItem(
  id: 'feed-a',
  name: 'Source A',
  version: '1',
  enabled: false,
  accessDomains: [],
);

const _invalidFeed = FeedMetaItem(
  id: 'feed-invalid',
  name: 'Broken source',
  version: '1',
  enabled: true,
  accessDomains: [],
  error: 'script failed to load',
);

Widget _testApp(Widget child) {
  return MaterialApp(
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('long source summaries and error states fit narrow screens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        child: _testApp(
          Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(1.5)),
              child: const FeedCard(
                feed: FeedMetaItem(
                  id: 'broken',
                  name:
                      'A long source title that must wrap without overflowing',
                  version: '1.0.0',
                  enabled: false,
                  author: 'An unusually long author name',
                  accessDomains: [],
                  error: 'Invalid script',
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ConfigurationListCard), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('an invalid feed skips auth capability and status checks', () async {
    final container = ProviderContainer(
      overrides: [
        // Auth methods are deliberately not configured: reaching either one
        // makes FakeFeedService throw and fails this regression test.
        feedServiceProvider.overrideWithValue(FakeFeedService()),
      ],
    );
    addTearDown(container.dispose);

    final status = await container.read(
      feedAuthStatusProvider((feedId: _invalidFeed.id, isValid: false)).future,
    );

    expect(status, isNull);
  });

  testWidgets('list is read-only and the detail sheet pauses a feed', (
    tester,
  ) async {
    final toggled = <(String, bool)>[];
    final service = FakeFeedService(
      listFeedsHandler: () async => [_feedA],
      listBookshelfHandler: () async => [],
      setFeedEnabledHandler: (feedId, enabled) async {
        toggled.add((feedId, enabled));
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          feedServiceProvider.overrideWithValue(service),
          feedAuthStatusProvider.overrideWith((ref, feedId) => null),
          appDataDirectorySetProvider.overrideWith(
            (ref) async => const AppDataDirectoryResult(feedCount: 1),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                final items = ref.watch(feedListProvider).items;
                if (items.isEmpty) return const SizedBox.shrink();
                return ListView(children: [FeedCard(feed: items.first)]);
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ConfigurationListCard), findsOneWidget);
    expect(find.text('Enabled'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    expect(find.byType(IconButton), findsNothing);
    expect(toggled, isEmpty);

    await tester.tap(find.text('Source A'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(toggled, [('feed-a', false)]);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Paused'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
  });

  testWidgets('a paused feed shows the paused badge', (tester) async {
    final service = FakeFeedService(
      listFeedsHandler: () async => [_feedAPaused],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          feedServiceProvider.overrideWithValue(service),
          feedAuthStatusProvider.overrideWith((ref, feedId) => null),
          appDataDirectorySetProvider.overrideWith(
            (ref) async => const AppDataDirectoryResult(feedCount: 1),
          ),
        ],
        child: _testApp(
          Consumer(
            builder: (context, ref, _) {
              final items = ref.watch(feedListProvider).items;
              if (items.isEmpty) return const SizedBox.shrink();
              return ListView(children: [FeedCard(feed: items.first)]);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Paused'), findsOneWidget);
  });

  testWidgets(
    'tapping the card opens the detail sheet with metadata and actions',
    (tester) async {
      final service = FakeFeedService(
        listFeedsHandler: () async => [_feedA],
        listBookshelfHandler: () async => const [
          BookshelfItemModel(
            feedId: 'feed-a',
            sourceBookId: 'book-1',
            title: 'Book one',
            author: 'Author',
            addedAtUnixMs: 1,
          ),
          BookshelfItemModel(
            feedId: 'feed-a',
            sourceBookId: 'book-2',
            title: 'Book two',
            author: 'Author',
            addedAtUnixMs: 2,
          ),
        ],
      );
      var deleteRequested = false;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            feedServiceProvider.overrideWithValue(service),
            feedAuthStatusProvider.overrideWith((ref, feedId) => null),
            appDataDirectorySetProvider.overrideWith(
              (ref) async => const AppDataDirectoryResult(feedCount: 1),
            ),
          ],
          child: _testApp(
            Consumer(
              builder: (context, ref, _) {
                final items = ref.watch(feedListProvider).items;
                if (items.isEmpty) return const SizedBox.shrink();
                return ListView(
                  children: [
                    FeedCard(
                      feed: items.first,
                      onDelete: () async => deleteRequested = true,
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Source A'));
      await tester.pumpAndSettle();

      // The sheet carries the metadata and actions the card omits.
      expect(find.text('A fixture source for tests.'), findsOneWidget);
      expect(find.text('ID'), findsOneWidget);
      expect(find.text('feed-a'), findsOneWidget);
      expect(find.text('Base URL'), findsOneWidget);
      expect(find.text('https://example.com'), findsOneWidget);
      expect(find.text('Access domains'), findsOneWidget);
      expect(find.text('example.com'), findsOneWidget);
      expect(find.text('cdn.example.com'), findsOneWidget);
      expect(find.text('Source'), findsOneWidget);
      expect(find.text('https://example.com/source-a.js'), findsOneWidget);
      expect(find.text('Shelved books'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.byType(SwitchListTile), findsOneWidget);
      expect(find.text('Delete feed'), findsOneWidget);

      // Auth is unsupported in this harness: no auth section.
      expect(find.text('Login'), findsNothing);

      // The delete button closes the sheet and hands over to the page.
      await tester.tap(find.text('Delete feed'));
      await tester.pumpAndSettle();

      expect(find.text('Delete feed'), findsNothing);
      expect(deleteRequested, isTrue);
    },
  );
}

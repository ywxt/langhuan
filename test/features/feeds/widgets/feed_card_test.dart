import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:langhuan/features/feeds/feed_providers.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/features/feeds/widgets/feed_card.dart';
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
);

const _feedAPaused = FeedMetaItem(
  id: 'feed-a',
  name: 'Source A',
  version: '1',
  enabled: false,
  accessDomains: [],
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
  testWidgets('the status button pauses a feed through the notifier', (
    tester,
  ) async {
    final toggled = <(String, bool)>[];
    final service = FakeFeedService(
      listFeedsHandler: () async => [_feedA],
      setFeedEnabledHandler: (feedId, enabled) async {
        toggled.add((feedId, enabled));
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          feedServiceProvider.overrideWithValue(service),
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

    expect(find.byTooltip('Pause feed'), findsOneWidget);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);

    await tester.tap(find.byTooltip('Pause feed'));
    await tester.pumpAndSettle();

    // The service was asked to pause, and the rebuilt card reflects it:
    // The action changes to resume and the content is dimmed.
    expect(toggled, [('feed-a', false)]);
    expect(find.byTooltip('Resume feed'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(
      find.byWidgetPredicate((w) => w is Opacity && w.opacity == 0.55),
      findsNWidgets(2),
      reason: 'avatar and text column dim while paused',
    );
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

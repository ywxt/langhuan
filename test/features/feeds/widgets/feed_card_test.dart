import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:langhuan/features/feeds/feed_providers.dart';
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
);

void main() {
  testWidgets('the switch pauses a feed through the notifier', (tester) async {
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

    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    // The service was asked to pause, and the rebuilt card reflects it:
    // switch off, content dimmed.
    expect(toggled, [('feed-a', false)]);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(
      find.byWidgetPredicate(
        (w) => w is Opacity && w.opacity == 0.55,
      ),
      findsNWidgets(2),
      reason: 'avatar and text column dim while paused',
    );
  });
}

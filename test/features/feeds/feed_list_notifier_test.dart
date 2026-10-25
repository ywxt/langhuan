import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/feeds/feed_providers.dart';
import 'package:langhuan/rust_init.dart';
import 'package:langhuan/src/rust/api/types.dart';

import 'fake_feed_service.dart';

const _feedA = FeedMetaItem(
  id: 'feed-a',
  name: 'Source A',
  version: '1',
  enabled: true,
);
const _feedB = FeedMetaItem(
  id: 'feed-b',
  name: 'Source B',
  version: '1',
  enabled: true,
);

void main() {
  ProviderContainer container(FakeFeedService service) {
    final c = ProviderContainer(
      overrides: [
        feedServiceProvider.overrideWithValue(service),
        appDataDirectorySetProvider.overrideWith(
          (ref) async => const AppDataDirectoryResult(feedCount: 2),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('FeedListNotifier', () {
    /// Wait for the (overridden, async) bootstrap to resolve, then run an
    /// explicit load so the assertions are deterministic.
    Future<void> loadFeeds(ProviderContainer c) async {
      await c.read(appDataDirectorySetProvider.future);
      await c.read(feedListProvider.notifier).load();
    }

    test('load lists the installed feeds', () async {
      final c = container(
        FakeFeedService(listFeedsHandler: () async => [_feedA, _feedB]),
      );

      await loadFeeds(c);

      final state = c.read(feedListProvider);
      expect(state.isLoading, isFalse);
      expect(state.hasError, isFalse);
      expect(state.items.map((feed) => feed.id), ['feed-a', 'feed-b']);
    });

    test('load surfaces listing errors', () async {
      final c = container(
        FakeFeedService(
          listFeedsHandler: () async => throw StateError('registry down'),
        ),
      );

      await loadFeeds(c);

      final state = c.read(feedListProvider);
      expect(state.isLoading, isFalse);
      expect(state.hasError, isTrue);
      expect(state.error, isA<StateError>());
    });

    test('removeFeed drops the feed and clears a matching selection', () async {
      final c = container(
        FakeFeedService(
          listFeedsHandler: () async => [_feedB],
          removeFeedHandler: (feedId) async {},
        ),
      );
      // Seed a loaded list and a selection pointing at the doomed feed.
      await loadFeeds(c);
      c.read(selectedFeedProvider.notifier).select(FeedSelectionOne(_feedA));

      final error = await c
          .read(feedListProvider.notifier)
          .removeFeed(feedId: 'feed-a');

      expect(error, isNull);
      expect(c.read(feedListProvider).items, [_feedB]);
      expect(
        c.read(selectedFeedProvider),
        isNull,
        reason: 'the selection pointed at the removed feed',
      );
    });

    test(
      'removeFeed keeps the selection when another feed is removed',
      () async {
        final c = container(
          FakeFeedService(
            listFeedsHandler: () async => [_feedA],
            removeFeedHandler: (feedId) async {},
          ),
        );
        await loadFeeds(c);
        c.read(selectedFeedProvider.notifier).select(FeedSelectionOne(_feedA));

        final error = await c
            .read(feedListProvider.notifier)
            .removeFeed(feedId: 'feed-b');

        expect(error, isNull);
        expect(c.read(selectedFeedProvider), isA<FeedSelectionOne>());
      },
    );

    test('removeFeed reports failures and keeps the list', () async {
      final c = container(
        FakeFeedService(
          listFeedsHandler: () async => [_feedA, _feedB],
          removeFeedHandler: (feedId) async => throw StateError('in use'),
        ),
      );
      await loadFeeds(c);

      final error = await c
          .read(feedListProvider.notifier)
          .removeFeed(feedId: 'feed-a');

      expect(error, isNotNull);
      expect(c.read(feedListProvider).items.map((feed) => feed.id), [
        'feed-a',
        'feed-b',
      ]);
      expect(c.read(feedListProvider).removingFeedId, isNull);
    });

    test('setFeedEnabled flips the item optimistically', () async {
      final toggled = <(String, bool)>[];
      final c = container(
        FakeFeedService(
          listFeedsHandler: () async => [_feedA, _feedB],
          setFeedEnabledHandler: (feedId, enabled) async {
            toggled.add((feedId, enabled));
          },
        ),
      );
      await loadFeeds(c);
      // The notifier's build schedules its own microtask load; let it
      // settle so it cannot clobber the optimistic flip below.
      await Future<void>.delayed(Duration.zero);

      final error = await c
          .read(feedListProvider.notifier)
          .setFeedEnabled(feedId: 'feed-a', enabled: false);

      expect(error, isNull);
      expect(toggled, [('feed-a', false)]);
      final items = c.read(feedListProvider).items;
      expect(items.first.id, 'feed-a');
      expect(items.first.enabled, false, reason: 'flipped in place');
      expect(items.last.enabled, true, reason: 'sibling untouched');
    });

    test('setFeedEnabled reverts the item when the backend fails', () async {
      final c = container(
        FakeFeedService(
          listFeedsHandler: () async => [_feedA, _feedB],
          setFeedEnabledHandler: (feedId, enabled) async =>
              throw StateError('locked'),
        ),
      );
      await loadFeeds(c);
      // Same double-load drain as above.
      await Future<void>.delayed(Duration.zero);

      final error = await c
          .read(feedListProvider.notifier)
          .setFeedEnabled(feedId: 'feed-a', enabled: false);

      expect(error, isNotNull);
      expect(
        c.read(feedListProvider).items.every((feed) => feed.enabled),
        isTrue,
        reason: 'the optimistic flip is rolled back',
      );
    });
  });
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/bookshelf_provider.dart';
import 'package:langhuan/features/feeds/feed_providers.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/rust_init.dart';
import 'package:langhuan/src/rust/api/types.dart';
import 'dart:async';

import '../feeds/fake_feed_service.dart';

void main() {
  test('bookshelf provider stays loading while app data bootstraps', () {
    final container = ProviderContainer(
      overrides: [
        appDataDirectorySetProvider.overrideWith((ref) async {
          // Keep bootstrap pending so bookshelf notifier must not schedule load.
          return Completer<AppDataDirectoryResult>().future;
        }),
      ],
    );
    addTearDown(container.dispose);

    final state = container.read(bookshelfProvider);
    expect(state.isLoading, isTrue);
    expect(state.hasError, isFalse);
    expect(state.items, isEmpty);
  });

  test('bookshelf provider exposes bootstrap error outcome', () async {
    final container = ProviderContainer(
      overrides: [
        appDataDirectorySetProvider.overrideWith((ref) async {
          throw Exception('bootstrap failed');
        }),
      ],
    );
    addTearDown(container.dispose);

    // Force both providers to be active so the error propagates.
    container.listen(appDataDirectorySetProvider, (_, _) {});
    container.listen(bookshelfProvider, (_, _) {});

    // Wait for the error to propagate through the provider graph.
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final state = container.read(bookshelfProvider);
    expect(state.isLoading, isFalse);
    expect(state.hasError, isTrue);
    expect(state.error, isA<BookshelfError>());
    final error = state.error as BookshelfError;
    expect(error.type, BookshelfErrorType.loadFailed);
  });

  test('removeFeed immediately drops every item from that feed', () async {
    const items = [
      BookshelfItemModel(
        feedId: 'removed',
        sourceBookId: 'book-a',
        title: 'A',
        author: 'Author',
        addedAtUnixMs: 1,
      ),
      BookshelfItemModel(
        feedId: 'kept',
        sourceBookId: 'book-b',
        title: 'B',
        author: 'Author',
        addedAtUnixMs: 2,
      ),
      BookshelfItemModel(
        feedId: 'removed',
        sourceBookId: 'book-c',
        title: 'C',
        author: 'Author',
        addedAtUnixMs: 3,
      ),
    ];
    final container = ProviderContainer(
      overrides: [
        feedServiceProvider.overrideWithValue(
          FakeFeedService(listBookshelfHandler: () async => items),
        ),
        appDataDirectorySetProvider.overrideWith(
          (ref) async => const AppDataDirectoryResult(feedCount: 2),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(appDataDirectorySetProvider.future);
    await container.read(bookshelfProvider.notifier).load();
    container.read(bookshelfProvider.notifier).removeFeed('removed');

    expect(
      container.read(bookshelfProvider).items.map((item) => item.stableId),
      ['kept:book-b'],
    );
  });

  test(
    'remove propagates service failures instead of returning an error variant',
    () async {
      final container = ProviderContainer(
        overrides: [
          feedServiceProvider.overrideWithValue(
            FakeFeedService(
              removeFromBookshelfHandler: () async =>
                  throw StateError('database unavailable'),
            ),
          ),
          appDataDirectorySetProvider.overrideWith(
            (ref) async => const AppDataDirectoryResult(feedCount: 1),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(appDataDirectorySetProvider.future);

      await expectLater(
        container
            .read(bookshelfProvider.notifier)
            .remove(feedId: 'feed', sourceBookId: 'book'),
        throwsA(isA<StateError>()),
      );
    },
  );

  test('shelved books follow feed pause and resume toggles', () async {
    const items = [
      BookshelfItemModel(
        feedId: 'feed-a',
        sourceBookId: 'book-1',
        title: 'One',
        author: 'Author',
        addedAtUnixMs: 1,
      ),
      BookshelfItemModel(
        feedId: 'feed-b',
        sourceBookId: 'book-2',
        title: 'Two',
        author: 'Author',
        addedAtUnixMs: 2,
      ),
    ];
    final container = ProviderContainer(
      overrides: [
        feedServiceProvider.overrideWithValue(
          FakeFeedService(
            listFeedsHandler: () async => const [
              FeedMetaItem(
                id: 'feed-a',
                name: 'Source A',
                version: '1',
                enabled: true,
              ),
              FeedMetaItem(
                id: 'feed-b',
                name: 'Source B',
                version: '1',
                enabled: true,
              ),
            ],
            listBookshelfHandler: () async => items,
            setFeedEnabledHandler: (feedId, enabled) async {},
          ),
        ),
        appDataDirectorySetProvider.overrideWith(
          (ref) async => const AppDataDirectoryResult(feedCount: 2),
        ),
      ],
    );
    addTearDown(container.dispose);

    // Keep both providers alive: the bookshelf listens to the feed list.
    container.listen(bookshelfProvider, (_, _) {});
    container.listen(feedListProvider, (_, _) {});

    await container.read(appDataDirectorySetProvider.future);
    await container.read(bookshelfProvider.notifier).load();
    await container.read(feedListProvider.notifier).load();

    // Pausing a feed flips its books' pause flag without a shelf reload.
    await container
        .read(feedListProvider.notifier)
        .setFeedEnabled(feedId: 'feed-a', enabled: false);
    await Future<void>.delayed(Duration.zero);

    var shelfItems = container.read(bookshelfProvider).items;
    expect(
      shelfItems.firstWhere((item) => item.feedId == 'feed-a').feedEnabled,
      isFalse,
    );
    expect(
      shelfItems.firstWhere((item) => item.feedId == 'feed-b').feedEnabled,
      isTrue,
    );

    // Resuming restores it.
    await container
        .read(feedListProvider.notifier)
        .setFeedEnabled(feedId: 'feed-a', enabled: true);
    await Future<void>.delayed(Duration.zero);

    shelfItems = container.read(bookshelfProvider).items;
    expect(
      shelfItems.firstWhere((item) => item.feedId == 'feed-a').feedEnabled,
      isTrue,
    );
  });
}

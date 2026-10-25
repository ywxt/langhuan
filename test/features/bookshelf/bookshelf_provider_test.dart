import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/bookshelf_provider.dart';
import 'package:langhuan/features/feeds/feed_providers.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/rust_init.dart';
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
}

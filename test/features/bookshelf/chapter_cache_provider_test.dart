import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/chapter_cache_provider.dart';
import 'package:langhuan/features/feeds/feed_providers.dart';
import 'package:langhuan/rust_init.dart';
import 'package:langhuan/shared/chapter_cache_changes.dart';

import '../feeds/fake_feed_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const first = (feedId: 'f', bookId: 'a');
  const second = (feedId: 'f', bookId: 'b');

  ProviderContainer containerFor(FakeFeedService service) => ProviderContainer(
    overrides: [
      feedServiceProvider.overrideWithValue(service),
      appDataDirectorySetProvider.overrideWith(
        (ref) async => const AppDataDirectoryResult(feedCount: 0),
      ),
    ],
  );

  test(
    'one scoped query serves subscribers and invalidation targets affected books',
    () async {
      final data = <String, List<String>>{
        'a': ['one'],
        'b': ['two'],
      };
      final calls = <String, int>{};
      final container = containerFor(
        FakeFeedService(
          cachedChapterIdsHandler: (feed, book) async {
            calls.update(book, (value) => value + 1, ifAbsent: () => 1);
            return data[book]!;
          },
        ),
      );
      addTearDown(container.dispose);
      container.listen(cachedChapterIdsProvider(first), (_, _) {});
      container.listen(cachedChapterIdsProvider(first), (_, _) {});
      container.listen(cachedChapterIdsProvider(second), (_, _) {});
      expect(await container.read(cachedChapterIdsProvider(first).future), {
        'one',
      });
      expect(await container.read(cachedChapterIdsProvider(second).future), {
        'two',
      });
      expect(calls, {'a': 1, 'b': 1});
      data['a'] = ['three'];
      notifyChapterCacheChanged(feedId: 'f', bookId: 'a');
      expect(await container.read(cachedChapterIdsProvider(first).future), {
        'three',
      });
      expect(calls, {'a': 2, 'b': 1});
      notifyChapterCacheChanged(feedId: 'other');
      await container.pump();
      expect(calls, {'a': 2, 'b': 1});
      data.updateAll((key, value) => []);
      notifyChapterCacheChanged();
      expect(
        await container.read(cachedChapterIdsProvider(first).future),
        isEmpty,
      );
      expect(
        await container.read(cachedChapterIdsProvider(second).future),
        isEmpty,
      );
      expect(calls, {'a': 3, 'b': 2});
    },
  );

  test('failed refresh invalidates cache metadata after removal', () async {
    var ids = ['one'];
    final container = containerFor(
      FakeFeedService(cachedChapterIdsHandler: (feed, book) async => ids),
    );
    addTearDown(container.dispose);
    container.listen(cachedChapterIdsProvider(first), (_, _) {});
    expect(await container.read(cachedChapterIdsProvider(first).future), {
      'one',
    });
    await expectLater(
      trackChapterCacheChange<void>(
        () async {
          ids = [];
          throw StateError('refresh failed after clearing the chapter');
        },
        feedId: 'f',
        bookId: 'a',
      ),
      throwsStateError,
    );
    expect(
      await container.read(cachedChapterIdsProvider(first).future),
      isEmpty,
    );
  });

  test('old in-flight results cannot restore stale cached badges', () async {
    final old = Completer<List<String>>();
    var calls = 0;
    final container = containerFor(
      FakeFeedService(
        cachedChapterIdsHandler: (feed, book) {
          calls++;
          return calls == 1 ? old.future : Future.value(['new']);
        },
      ),
    );
    addTearDown(container.dispose);
    container.listen(cachedChapterIdsProvider(first), (_, _) {});
    await container.pump();
    notifyChapterCacheChanged(feedId: 'f', bookId: 'a');
    expect(await container.read(cachedChapterIdsProvider(first).future), {
      'new',
    });
    old.complete(['old']);
    await container.pump();
    expect(container.read(cachedChapterIdsProvider(first)).requireValue, {
      'new',
    });
  });

  test(
    'query failure stays unknown and a later cache change retries it',
    () async {
      var fail = true;
      final container = containerFor(
        FakeFeedService(
          cachedChapterIdsHandler: (feed, book) async {
            if (fail) throw StateError('database unavailable');
            return ['one'];
          },
        ),
      );
      addTearDown(container.dispose);
      container.listen(cachedChapterIdsProvider(first), (_, _) {});
      await expectLater(
        container.read(cachedChapterIdsProvider(first).future),
        throwsStateError,
      );
      expect(container.read(cachedChapterIdsProvider(first)).hasError, isTrue);
      fail = false;
      notifyChapterCacheChanged(feedId: 'f', bookId: 'a');
      expect(await container.read(cachedChapterIdsProvider(first).future), {
        'one',
      });
    },
  );
}

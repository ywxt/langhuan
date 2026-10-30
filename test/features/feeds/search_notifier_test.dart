import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/feeds/feed_providers.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/features/feeds/search_provider.dart';

import 'fake_feed_service.dart';

AggregatedSearchEventModel _item(String feedId, String name, String id) {
  return AggregatedSearchEventModel(
    feedId: feedId,
    feedName: name,
    item: SearchResultModel(id: id, title: 'Book $id', author: 'Author'),
  );
}

AggregatedSearchEventModel _error(String feedId, String name, String message) {
  return AggregatedSearchEventModel(
    feedId: feedId,
    feedName: name,
    error: message,
  );
}

void main() {
  ProviderContainer container(FakeFeedService service) {
    final c = ProviderContainer(
      overrides: [feedServiceProvider.overrideWithValue(service)],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('SearchNotifier', () {
    test('paginates aggregated events and groups them by feed', () async {
      final events = <AggregatedSearchEventModel>[
        for (var i = 0; i < 25; i++) _item('feed-a', 'Source A', 'a$i'),
        for (var i = 0; i < 20; i++) _item('feed-b', 'Source B', 'b$i'),
      ];
      final c = container(
        FakeFeedService(
          searchAllHandler: (keyword) => Stream.fromIterable(events),
        ),
      );
      final notifier = c.read(searchProvider.notifier);

      await notifier.searchAll(keyword: 'kw');
      var state = c.read(searchProvider);
      expect(state.keyword, 'kw');
      // Page 1 only reaches into feed-a's 25 items.
      expect(state.groups, hasLength(1));
      expect(state.groups.single.feedId, 'feed-a');
      expect(state.groups.single.items, hasLength(20));
      expect(state.hasMore, isTrue, reason: '25 events remain');

      await notifier.loadMore();
      state = c.read(searchProvider);
      // Page 2 finishes feed-a and starts feed-b.
      expect(state.groups, hasLength(2));
      expect(state.groups.expand((group) => group.items), hasLength(40));
      expect(state.hasMore, isTrue, reason: '5 events remain');

      await notifier.loadMore();
      state = c.read(searchProvider);
      expect(state.groups.expand((group) => group.items), hasLength(45));
      expect(state.hasMore, isFalse, reason: 'stream exhausted');

      // Group attribution: each source keeps its own items and name.
      final byId = {for (final group in state.groups) group.feedId: group};
      expect(byId['feed-a']!.feedName, 'Source A');
      expect(byId['feed-a']!.items, hasLength(25));
      expect(byId['feed-b']!.feedName, 'Source B');
      expect(byId['feed-b']!.items, hasLength(20));
    });

    test('a failed feed lands in its group without failing the run', () async {
      final c = container(
        FakeFeedService(
          searchAllHandler: (keyword) => Stream.fromIterable([
            _item('feed-a', 'Source A', 'a1'),
            _error('feed-b', 'Source B', 'source unavailable'),
            _item('feed-a', 'Source A', 'a2'),
          ]),
        ),
      );
      await c.read(searchProvider.notifier).searchAll(keyword: 'kw');

      final state = c.read(searchProvider);
      expect(state.hasError, isFalse);
      expect(state.hasItems, isTrue);
      final byId = {for (final group in state.groups) group.feedId: group};
      expect(byId['feed-a']!.items, hasLength(2));
      expect(byId['feed-a']!.error, isNull);
      expect(byId['feed-b']!.items, isEmpty);
      expect(byId['feed-b']!.error, 'source unavailable');
    });

    test('a stream failure becomes the global error', () async {
      final c = container(
        FakeFeedService(
          searchAllHandler: (keyword) =>
              Stream<AggregatedSearchEventModel>.error(StateError('boom')),
        ),
      );
      await c.read(searchProvider.notifier).searchAll(keyword: 'kw');

      final state = c.read(searchProvider);
      expect(state.hasError, isTrue);
      expect(state.groups, isEmpty);
      expect(state.hasMore, isFalse);
    });

    test('single-source search wraps its results in one group', () async {
      final c = container(
        FakeFeedService(
          searchHandler: (feedId, keyword) => Stream.fromIterable([
            const SearchResultModel(id: '1', title: 'One', author: 'A'),
            const SearchResultModel(id: '2', title: 'Two', author: 'B'),
          ]),
        ),
      );
      await c
          .read(searchProvider.notifier)
          .search(feedId: 'feed-a', feedName: 'Source A', keyword: 'kw');

      final state = c.read(searchProvider);
      expect(state.groups, hasLength(1));
      expect(state.groups.single.feedId, 'feed-a');
      expect(state.groups.single.feedName, 'Source A');
      expect(state.groups.single.items.map((item) => item.id), ['1', '2']);
    });

    test('deduplicates book ids across result pages for each feed', () async {
      final events = <AggregatedSearchEventModel>[
        for (var i = 0; i < 20; i++) _item('fanqie', 'Fanqie', 'book-$i'),
        _item('fanqie', 'Fanqie', 'book-19'),
        _item('fanqie', 'Fanqie', 'book-20'),
      ];
      final c = container(
        FakeFeedService(
          searchAllHandler: (keyword) => Stream.fromIterable(events),
        ),
      );
      final notifier = c.read(searchProvider.notifier);

      await notifier.searchAll(keyword: 'kw');
      await notifier.loadMore();

      final items = c.read(searchProvider).groups.single.items;
      expect(items, hasLength(21));
      expect(items.map((item) => item.id).toSet(), hasLength(21));
    });

    test('retry repeats the last search kind', () async {
      var searchCalls = 0;
      var searchAllCalls = 0;
      final c = container(
        FakeFeedService(
          searchHandler: (feedId, keyword) {
            searchCalls++;
            return const Stream.empty();
          },
          searchAllHandler: (keyword) {
            searchAllCalls++;
            return const Stream.empty();
          },
        ),
      );
      final notifier = c.read(searchProvider.notifier);

      await notifier.search(feedId: 'f', feedName: 'F', keyword: 'kw');
      await notifier.retry();
      expect(searchCalls, 2);
      expect(searchAllCalls, 0);

      await notifier.searchAll(keyword: 'kw');
      await notifier.retry();
      expect(searchCalls, 2);
      expect(searchAllCalls, 2);
    });

    test(
      'a new run supersedes the pending one and cancels its stream',
      () async {
        var firstCancelled = false;
        final first = StreamController<AggregatedSearchEventModel>();
        final second = StreamController<AggregatedSearchEventModel>();
        first.onCancel = () => firstCancelled = true;

        var calls = 0;
        final c = container(
          FakeFeedService(
            searchAllHandler: (keyword) =>
                calls++ == 0 ? first.stream : second.stream,
          ),
        );
        final notifier = c.read(searchProvider.notifier);

        // Run 1 pulls from `first`, which never emits. Its future never
        // completes once superseded — that is fine, it must not touch state
        // again, which the assertions below prove.
        unawaited(notifier.searchAll(keyword: 'a'));
        await Future<void>.delayed(Duration.zero);

        // Run 2 supersedes it.
        final pending2 = notifier.searchAll(keyword: 'b');
        await Future<void>.delayed(Duration.zero);

        second.add(_item('feed-x', 'X', 'x1'));
        // The StreamIterator keeps its subscription after the stream ends, so
        // awaiting close() would never complete.
        unawaited(second.close());
        await pending2;

        final state = c.read(searchProvider);
        expect(state.keyword, 'b');
        expect(state.groups, hasLength(1));
        expect(state.groups.single.feedId, 'feed-x');
        expect(firstCancelled, isTrue, reason: 'run 1 was cancelled');
      },
    );

    test('cancelAndClear resets the state', () async {
      final events = [
        for (var i = 0; i < 20; i++) _item('feed-a', 'Source A', 'a$i'),
      ];
      final c = container(
        FakeFeedService(
          searchAllHandler: (keyword) => Stream.fromIterable(events),
        ),
      );
      final notifier = c.read(searchProvider.notifier);

      await notifier.searchAll(keyword: 'kw');
      expect(c.read(searchProvider).hasItems, isTrue);
      expect(c.read(searchProvider).hasMore, isTrue);

      await notifier.cancelAndClear();
      final state = c.read(searchProvider);
      expect(state.keyword, isEmpty);
      expect(state.groups, isEmpty);
      expect(state.isLoading, isFalse);
      expect(state.hasError, isFalse);
    });
  });
}

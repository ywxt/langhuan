import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/bookshelf_provider.dart';
import 'package:langhuan/features/feeds/feed_providers.dart';
import 'package:langhuan/features/feeds/feed_service.dart';

import '../feeds/fake_feed_service.dart';

void main() {
  ProviderContainer container(FakeFeedService service) {
    final c = ProviderContainer(
      overrides: [feedServiceProvider.overrideWithValue(service)],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('BookshelfUpdatesNotifier', () {
    test('check aggregates badges and per-book failures', () async {
      final c = container(
        FakeFeedService(
          bookshelfUpdatesHandler: () => Stream.fromIterable(const [
            BookshelfUpdateModel(
              feedId: 'f1',
              sourceBookId: 'b1',
              newChapters: 3,
            ),
            BookshelfUpdateModel(
              feedId: 'f1',
              sourceBookId: 'b2',
              newChapters: 0,
            ),
            BookshelfUpdateModel(
              feedId: 'f1',
              sourceBookId: 'b3',
              newChapters: 0,
              error: 'source unavailable',
            ),
          ]),
        ),
      );

      await c.read(bookshelfUpdatesProvider.notifier).check();

      final state = c.read(bookshelfUpdatesProvider);
      expect(state.isChecking, isFalse);
      expect(state.lastError, isNull);
      expect(state.newChaptersByBook, {'f1:b1': 3});
      expect(state.failedBooks, {'f1:b3': 'source unavailable'});
    });

    test('a fatal stream failure preserves badges and records lastError', () async {
      final c = container(
        FakeFeedService(
          bookshelfUpdatesHandler: () async* {
            yield const BookshelfUpdateModel(
              feedId: 'f1',
              sourceBookId: 'b1',
              newChapters: 5,
            );
            throw StateError('boom');
          },
        ),
      );

      await c.read(bookshelfUpdatesProvider.notifier).check();

      final state = c.read(bookshelfUpdatesProvider);
      expect(state.isChecking, isFalse);
      expect(state.lastError, isA<StateError>());
      expect(state.newChaptersByBook, {'f1:b1': 5});
      expect(state.failedBooks, isEmpty);
    });

    test('check is not re-entrant', () async {
      final controller = StreamController<BookshelfUpdateModel>();
      addTearDown(() {
        unawaited(controller.close());
      });
      var calls = 0;
      final c = container(
        FakeFeedService(
          bookshelfUpdatesHandler: () {
            calls++;
            return controller.stream;
          },
        ),
      );
      final notifier = c.read(bookshelfUpdatesProvider.notifier);

      final first = notifier.check();
      await Future<void>.delayed(Duration.zero);
      expect(c.read(bookshelfUpdatesProvider).isChecking, isTrue);

      await notifier.check();
      expect(calls, 1, reason: 'the second call returns immediately');

      controller.add(
        const BookshelfUpdateModel(feedId: 'f1', sourceBookId: 'b1', newChapters: 1),
      );
      await controller.close();
      await first;
      expect(c.read(bookshelfUpdatesProvider).isChecking, isFalse);
    });

    test('clear removes one badge; remove aliases it', () async {
      final c = container(
        FakeFeedService(
          bookshelfUpdatesHandler: () => Stream.fromIterable(const [
            BookshelfUpdateModel(feedId: 'f1', sourceBookId: 'b1', newChapters: 2),
            BookshelfUpdateModel(feedId: 'f1', sourceBookId: 'b2', newChapters: 7),
          ]),
        ),
      );
      final notifier = c.read(bookshelfUpdatesProvider.notifier);
      await notifier.check();
      expect(c.read(bookshelfUpdatesProvider).newChaptersByBook, {
        'f1:b1': 2,
        'f1:b2': 7,
      });

      notifier.clear('f1', 'b1');
      expect(
        c.read(bookshelfUpdatesProvider).newChaptersByBook,
        {'f1:b2': 7},
        reason: 'clear removes exactly the seen book',
      );

      notifier.remove('f1', 'b2');
      expect(c.read(bookshelfUpdatesProvider).newChaptersByBook, isEmpty);
    });
  });
}

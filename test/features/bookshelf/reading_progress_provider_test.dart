import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/reading_progress_provider.dart';
import 'package:langhuan/features/feeds/feed_providers.dart';
import 'package:langhuan/features/feeds/feed_service.dart';

import '../feeds/fake_feed_service.dart';

ReadingProgressModel _saved(String book, String chapter) =>
    ReadingProgressModel(
      feedId: 'f',
      bookId: book,
      chapterId: chapter,
      paragraphId: 'p',
      updatedAtMs: 1,
    );

void main() {
  for (final fails in [false, true]) {
    test(
      'a superseded book load cannot replace current progress or errors: $fails',
      () async {
        final old = Completer<ReadingProgressModel?>();
        final container = ProviderContainer(
          overrides: [
            feedServiceProvider.overrideWithValue(
              FakeFeedService(
                getReadingProgressHandler: (f, b) => b == 'old'
                    ? old.future
                    : Future.value(_saved('new', 'new-chapter')),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        final notifier = container.read(readingProgressProvider.notifier);
        final pending = notifier.load(
          feedId: 'f',
          bookId: 'old',
          fallbackChapterId: 'old-fallback',
        );
        await notifier.load(
          feedId: 'f',
          bookId: 'new',
          fallbackChapterId: 'new-fallback',
        );
        if (fails) {
          old.completeError(StateError('old book failed'));
        } else {
          old.complete(_saved('old', 'old-chapter'));
        }
        await pending;
        final state = container.read(readingProgressProvider);
        expect(state.bookId, 'new');
        expect(state.activeChapterId, 'new-chapter');
        expect(state.progress?.bookId, 'new');
        expect(state.error, isNull);
      },
    );
  }

  test(
    'saving records the submitted position rather than the later viewport',
    () async {
      final gate = Completer<void>();
      final container = ProviderContainer(
        overrides: [
          feedServiceProvider.overrideWithValue(
            FakeFeedService(
              setReadingProgressHandler: (f, b, c, p, offset) => gate.future,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(readingProgressProvider.notifier);
      final pending = notifier.save(
        feedId: 'f',
        bookId: 'b',
        chapterId: 'c1',
        paragraphId: 'p1',
      );
      notifier.setActivePosition(
        chapterId: 'c2',
        paragraphId: 'p2',
        paragraphOffset: 0,
        paragraphCharOffset: 0,
      );
      gate.complete();
      await pending;
      final state = container.read(readingProgressProvider);
      expect(state.activeChapterId, 'c2');
      expect(state.progress?.chapterId, 'c1');
      expect(state.progress?.paragraphId, 'p1');
    },
  );

  test(
    'a save from the previous book cannot overwrite the current saved state',
    () async {
      final gate = Completer<void>();
      final container = ProviderContainer(
        overrides: [
          feedServiceProvider.overrideWithValue(
            FakeFeedService(
              getReadingProgressHandler: (f, b) async =>
                  _saved(b, 'new-chapter'),
              setReadingProgressHandler: (f, b, c, p, offset) => gate.future,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(readingProgressProvider.notifier);
      final pending = notifier.save(
        feedId: 'f',
        bookId: 'old',
        chapterId: 'old-chapter',
        paragraphId: 'p',
      );
      await notifier.load(
        feedId: 'f',
        bookId: 'new',
        fallbackChapterId: 'fallback',
      );
      gate.complete();
      await pending;
      final state = container.read(readingProgressProvider);
      expect(state.progress?.bookId, 'new');
      expect(state.progress?.updatedAtMs, 1);
      expect(state.isSaving, isFalse);
    },
  );
  test('late saves cannot replace a newer completed save', () async {
    final first = Completer<void>(), second = Completer<void>();
    final container = ProviderContainer(
      overrides: [
        feedServiceProvider.overrideWithValue(
          FakeFeedService(
            setReadingProgressHandler: (f, b, c, p, offset) =>
                c == 'c1' ? first.future : second.future,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(readingProgressProvider.notifier);
    final oldSave = notifier.save(
      feedId: 'f',
      bookId: 'b',
      chapterId: 'c1',
      paragraphId: 'p1',
    );
    final newSave = notifier.save(
      feedId: 'f',
      bookId: 'b',
      chapterId: 'c2',
      paragraphId: 'p2',
    );
    second.complete();
    await newSave;
    first.complete();
    await oldSave;
    expect(container.read(readingProgressProvider).progress?.chapterId, 'c2');
  });

  test('clearing and disposal invalidate outstanding work', () async {
    final loaded = Completer<ReadingProgressModel?>();
    final saved = Completer<void>();
    final container = ProviderContainer(
      overrides: [
        feedServiceProvider.overrideWithValue(
          FakeFeedService(
            getReadingProgressHandler: (f, b) => loaded.future,
            setReadingProgressHandler: (f, b, c, p, offset) => saved.future,
          ),
        ),
      ],
    );
    final notifier = container.read(readingProgressProvider.notifier);
    final pendingLoad = notifier.load(
      feedId: 'f',
      bookId: 'b',
      fallbackChapterId: 'c',
    );
    notifier.clear();
    loaded.complete(_saved('b', 'late'));
    await pendingLoad;
    expect(container.read(readingProgressProvider).bookId, isEmpty);
    final pendingSave = notifier.save(
      feedId: 'f',
      bookId: 'b',
      chapterId: 'c',
      paragraphId: 'p',
    );
    container.dispose();
    saved.complete();
    await pendingSave;
  });
}

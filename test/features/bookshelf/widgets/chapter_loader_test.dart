import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/widgets/chapter_loader.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/src/bindings/signals/signals.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Mock content provider
// ─────────────────────────────────────────────────────────────────────────────

class MockContentProvider implements ChapterContentProvider {
  int _counter = 0;

  /// Chapters that should fail immediately.
  Set<String> failingChapters = {};

  /// Chapters that should complete with content immediately.
  Map<String, List<ParagraphContent>> immediateContent = {};

  /// Chapters that should keep streaming (used to simulate in-flight loads).
  Map<String, Stream<ParagraphContent>> delayedStreams = {};

  /// Last request id assigned per chapter.
  final Map<String, String> requestIdByChapter = {};

  /// All cancelled request ids.
  final List<String> cancelledRequestIds = [];

  @override
  ({String requestId, Stream<ParagraphContent> stream}) fetchChapter({
    required String feedId,
    required String bookId,
    required String chapterId,
  }) {
    final requestId = 'mock-req-${_counter++}';
    requestIdByChapter[chapterId] = requestId;

    if (failingChapters.contains(chapterId)) {
      return (
        requestId: requestId,
        stream: Stream.error(
          FeedStreamException(
            requestId: requestId,
            message: 'Mock error for $chapterId',
            retriedCount: 0,
          ),
        ),
      );
    }

    final delayed = delayedStreams[chapterId];
    if (delayed != null) {
      return (requestId: requestId, stream: delayed);
    }

    final items = immediateContent[chapterId] ?? [];
    return (requestId: requestId, stream: Stream.fromIterable(items));
  }

  @override
  void cancel(String requestId) {
    cancelledRequestIds.add(requestId);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Test helpers
// ─────────────────────────────────────────────────────────────────────────────

List<ChapterInfoModel> makeChapters(int count) {
  return List.generate(
    count,
    (i) => ChapterInfoModel(id: 'ch-$i', title: 'Chapter ${i + 1}', index: i),
  );
}

const _sampleContent = [
  ParagraphContentTitle(text: 'Title'),
  ParagraphContentText(content: 'Body text'),
];

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  late MockContentProvider provider;

  setUp(() {
    provider = MockContentProvider();
  });

  group('ChapterLoader — construction', () {
    test('initialises with correct chapter metadata', () {
      final chapters = makeChapters(5);
      final loader = ChapterLoader(
        feedId: 'f1',
        bookId: 'b1',
        chapters: chapters,
        contentProvider: provider,
      );

      expect(loader.minTocIndex, 0);
      expect(loader.maxTocIndex, 4);
      expect(loader.chapters, hasLength(5));
      expect(loader.slots, isEmpty);
      expect(loader.currentChapterId, isNull);

      loader.dispose();
    });

    test('handles empty chapter list', () {
      final loader = ChapterLoader(
        feedId: 'f1',
        bookId: 'b1',
        chapters: const [],
        contentProvider: provider,
      );

      expect(loader.minTocIndex, 0);
      expect(loader.maxTocIndex, -1);
      expect(loader.hasOlderUnloaded, isFalse);
      expect(loader.hasNewerUnloaded, isFalse);

      loader.dispose();
    });
  });

  group('ChapterLoader — loadInitial', () {
    test('loads initial chapter and cascading preloads', () async {
      final chapters = makeChapters(5);
      // Provide content for all chapters since cascading preload will load them.
      for (int i = 0; i < 5; i++) {
        provider.immediateContent['ch-$i'] = _sampleContent;
      }

      final loader = ChapterLoader(
        feedId: 'f1',
        bookId: 'b1',
        chapters: chapters,
        contentProvider: provider,
      );

      await loader.loadInitial('ch-2');

      // Cascading preload: ch-2 → preload ch-1,ch-3 → ch-1 loads → preload ch-0,
      // ch-3 loads → preload ch-4. All 5 chapters loaded.
      expect(loader.slots, hasLength(5));
      expect(loader.slots[0].chapterId, 'ch-0');
      expect(loader.slots[4].chapterId, 'ch-4');
      expect(loader.slots.every((s) => s.isReady), isTrue);
      expect(loader.currentChapterId, 'ch-2');

      loader.dispose();
    });

    test('throws when initial chapter fails', () async {
      final chapters = makeChapters(3);
      provider.failingChapters.add('ch-1');

      final loader = ChapterLoader(
        feedId: 'f1',
        bookId: 'b1',
        chapters: chapters,
        contentProvider: provider,
      );

      await expectLater(
        () => loader.loadInitial('ch-1'),
        throwsA(isA<FeedStreamException>()),
      );

      loader.dispose();
    });

    test('preload failures are stored as error slots', () async {
      final chapters = makeChapters(3);
      provider.immediateContent = {'ch-1': _sampleContent};
      provider.failingChapters.addAll(['ch-0', 'ch-2']);

      final loader = ChapterLoader(
        feedId: 'f1',
        bookId: 'b1',
        chapters: chapters,
        contentProvider: provider,
      );

      // Should not throw even though preloads fail.
      await loader.loadInitial('ch-1');

      expect(loader.slots, hasLength(3));
      expect(loader.getSlot('ch-0')?.isError, isTrue);
      expect(loader.getSlot('ch-1')?.isReady, isTrue);
      expect(loader.getSlot('ch-2')?.isError, isTrue);

      loader.dispose();
    });

    test('loads first chapter with cascading preloads', () async {
      final chapters = makeChapters(3);
      for (int i = 0; i < 3; i++) {
        provider.immediateContent['ch-$i'] = _sampleContent;
      }

      final loader = ChapterLoader(
        feedId: 'f1',
        bookId: 'b1',
        chapters: chapters,
        contentProvider: provider,
      );

      await loader.loadInitial('ch-0');

      // ch-0 → preload ch-1 → ch-1 loads → preload ch-2.
      expect(loader.slots, hasLength(3));
      expect(loader.slots[0].chapterId, 'ch-0');
      expect(loader.slots[1].chapterId, 'ch-1');
      expect(loader.slots[2].chapterId, 'ch-2');

      loader.dispose();
    });

    test('loads last chapter with cascading preloads', () async {
      final chapters = makeChapters(3);
      for (int i = 0; i < 3; i++) {
        provider.immediateContent['ch-$i'] = _sampleContent;
      }

      final loader = ChapterLoader(
        feedId: 'f1',
        bookId: 'b1',
        chapters: chapters,
        contentProvider: provider,
      );

      await loader.loadInitial('ch-2');

      // ch-2 → preload ch-1 → ch-1 loads → preload ch-0.
      expect(loader.slots, hasLength(3));
      expect(loader.slots[0].chapterId, 'ch-0');
      expect(loader.slots[1].chapterId, 'ch-1');
      expect(loader.slots[2].chapterId, 'ch-2');

      loader.dispose();
    });
  });

  group('ChapterLoader — notifications', () {
    test('notifies listeners when slots change', () async {
      final chapters = makeChapters(3);
      for (int i = 0; i < 3; i++) {
        provider.immediateContent['ch-$i'] = _sampleContent;
      }

      final loader = ChapterLoader(
        feedId: 'f1',
        bookId: 'b1',
        chapters: chapters,
        contentProvider: provider,
      );

      int notifyCount = 0;
      loader.addListener(() => notifyCount++);

      await loader.loadInitial('ch-1');

      expect(notifyCount, greaterThan(0));

      loader.dispose();
    });
  });

  group('ChapterLoader — boundary detection', () {
    test('isAtBookStart when first ready slot is first chapter', () async {
      final chapters = makeChapters(3);
      for (int i = 0; i < 3; i++) {
        provider.immediateContent['ch-$i'] = _sampleContent;
      }

      final loader = ChapterLoader(
        feedId: 'f1',
        bookId: 'b1',
        chapters: chapters,
        contentProvider: provider,
      );

      await loader.loadInitial('ch-0');

      expect(loader.isAtBookStart, isTrue);
      // With cascading preload, all 3 chapters are loaded.
      expect(loader.isAtBookEnd, isTrue);

      loader.dispose();
    });

    test('isAtBookEnd when last ready slot is last chapter', () async {
      final chapters = makeChapters(3);
      for (int i = 0; i < 3; i++) {
        provider.immediateContent['ch-$i'] = _sampleContent;
      }

      final loader = ChapterLoader(
        feedId: 'f1',
        bookId: 'b1',
        chapters: chapters,
        contentProvider: provider,
      );

      await loader.loadInitial('ch-2');

      expect(loader.isAtBookEnd, isTrue);
      expect(loader.isAtBookStart, isTrue);

      loader.dispose();
    });

    test('not at boundaries when middle chapters loaded', () async {
      final chapters = makeChapters(10);
      // Only provide content for ch-4 and ch-5 (adjacent preloads will fail).
      provider.immediateContent = {
        'ch-4': _sampleContent,
        'ch-5': _sampleContent,
      };
      provider.failingChapters.addAll(['ch-3', 'ch-6']);

      final loader = ChapterLoader(
        feedId: 'f1',
        bookId: 'b1',
        chapters: chapters,
        contentProvider: provider,
      );

      await loader.loadInitial('ch-4');

      expect(loader.isAtBookStart, isFalse);
      expect(loader.isAtBookEnd, isFalse);
      expect(loader.hasOlderUnloaded, isTrue);
      expect(loader.hasNewerUnloaded, isTrue);

      loader.dispose();
    });
  });

  group('ChapterLoader — retryChapter', () {
    test('retries a failed chapter', () async {
      final chapters = makeChapters(3);
      provider.immediateContent = {'ch-1': _sampleContent};
      provider.failingChapters.addAll(['ch-0', 'ch-2']);

      final loader = ChapterLoader(
        feedId: 'f1',
        bookId: 'b1',
        chapters: chapters,
        contentProvider: provider,
      );

      await loader.loadInitial('ch-1');

      expect(loader.getSlot('ch-0')?.isError, isTrue);

      // Now make it succeed.
      provider.failingChapters.remove('ch-0');
      provider.immediateContent['ch-0'] = _sampleContent;

      await loader.retryChapter('ch-0');

      expect(loader.getSlot('ch-0')?.isReady, isTrue);

      loader.dispose();
    });
  });

  group('ChapterLoader — eviction', () {
    test('evicts farthest chapter when setCurrentChapter is called', () async {
      final chapters = makeChapters(8);
      for (int i = 0; i < 8; i++) {
        provider.immediateContent['ch-$i'] = _sampleContent;
      }

      final loader = ChapterLoader(
        feedId: 'f1',
        bookId: 'b1',
        chapters: chapters,
        maxLoaded: 3,
        contentProvider: provider,
      );

      await loader.loadInitial('ch-3');

      // Cascading preloads loaded all chapters. But eviction only happens
      // when setCurrentChapter is called (normally by the view).
      final slotsBefore = loader.slots.length;
      expect(slotsBefore, greaterThan(3));

      // Simulate user navigating to ch-5.
      loader.setCurrentChapter('ch-5');

      // Eviction should reduce to maxLoaded.
      // Give async operations time.
      await Future<void>.delayed(Duration.zero);

      expect(loader.slots.length, lessThan(slotsBefore));

      loader.dispose();
    });

    test('cancels in-flight request when evicted slot disappears', () async {
      final chapters = makeChapters(6);
      for (int i = 0; i < 5; i++) {
        provider.immediateContent['ch-$i'] = _sampleContent;
      }

      final ch5Controller = StreamController<ParagraphContent>();
      provider.delayedStreams['ch-5'] = ch5Controller.stream;

      final loader = ChapterLoader(
        feedId: 'f1',
        bookId: 'b1',
        chapters: chapters,
        maxLoaded: 3,
        contentProvider: provider,
      );

      await loader.loadInitial('ch-2');
      await Future<void>.delayed(Duration.zero);

      // Move current chapter to the beginning so farthest chapters are evicted.
      loader.setCurrentChapter('ch-0');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final ch5RequestId = provider.requestIdByChapter['ch-5'];
      expect(ch5RequestId, isNotNull);
      expect(provider.cancelledRequestIds, contains(ch5RequestId));

      await ch5Controller.close();
      loader.dispose();
    });
  });

  group('ChapterLoader — setCurrentChapter', () {
    test('updates currentChapterId', () async {
      final chapters = makeChapters(3);
      for (int i = 0; i < 3; i++) {
        provider.immediateContent['ch-$i'] = _sampleContent;
      }

      final loader = ChapterLoader(
        feedId: 'f1',
        bookId: 'b1',
        chapters: chapters,
        contentProvider: provider,
      );

      await loader.loadInitial('ch-1');
      expect(loader.currentChapterId, 'ch-1');

      loader.setCurrentChapter('ch-2');
      expect(loader.currentChapterId, 'ch-2');

      loader.dispose();
    });
  });

  group('ChapterLoader — updateSlot', () {
    test('updates a slot and notifies listeners', () async {
      final chapters = makeChapters(3);
      for (int i = 0; i < 3; i++) {
        provider.immediateContent['ch-$i'] = _sampleContent;
      }

      final loader = ChapterLoader(
        feedId: 'f1',
        bookId: 'b1',
        chapters: chapters,
        contentProvider: provider,
      );

      await loader.loadInitial('ch-1');

      int notifyCount = 0;
      loader.addListener(() => notifyCount++);

      loader.updateSlot('ch-1', (s) => s.copyWith(pages: const []));

      expect(notifyCount, 1);
      expect(loader.getSlot('ch-1')?.pages, isEmpty);

      loader.dispose();
    });

    test('no-op for non-existent slot', () async {
      final chapters = makeChapters(3);
      provider.immediateContent = {'ch-1': _sampleContent};

      final loader = ChapterLoader(
        feedId: 'f1',
        bookId: 'b1',
        chapters: chapters,
        contentProvider: provider,
      );

      await loader.loadInitial('ch-1');

      int notifyCount = 0;
      loader.addListener(() => notifyCount++);

      loader.updateSlot('non-existent', (s) => s);

      expect(notifyCount, 0);

      loader.dispose();
    });
  });

  group('ChapterLoader — chapterByTocIndex', () {
    test('returns chapter for valid index', () {
      final chapters = makeChapters(3);
      final loader = ChapterLoader(
        feedId: 'f1',
        bookId: 'b1',
        chapters: chapters,
        contentProvider: provider,
      );

      expect(loader.chapterByTocIndex(0)?.id, 'ch-0');
      expect(loader.chapterByTocIndex(2)?.id, 'ch-2');
      expect(loader.chapterByTocIndex(5), isNull);

      loader.dispose();
    });
  });

  group('ChapterLoader — chapterGlobalIndex', () {
    test('returns index for valid chapter', () {
      final chapters = makeChapters(3);
      final loader = ChapterLoader(
        feedId: 'f1',
        bookId: 'b1',
        chapters: chapters,
        contentProvider: provider,
      );

      expect(loader.chapterGlobalIndex('ch-0'), 0);
      expect(loader.chapterGlobalIndex('ch-2'), 2);
      expect(loader.chapterGlobalIndex('non-existent'), -1);

      loader.dispose();
    });
  });

  group('ChapterLoader — dispose', () {
    test('does not throw on dispose', () async {
      final chapters = makeChapters(3);
      provider.immediateContent = {'ch-1': _sampleContent};

      final loader = ChapterLoader(
        feedId: 'f1',
        bookId: 'b1',
        chapters: chapters,
        contentProvider: provider,
      );

      unawaited(loader.loadInitial('ch-1'));
      await Future<void>.delayed(Duration.zero);

      // Should not throw.
      loader.dispose();
    });
  });
}

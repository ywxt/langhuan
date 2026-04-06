import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/widgets/reader_types.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/src/bindings/signals/signals.dart';

void main() {
  group('normalizeChapterErrorMessage', () {
    test('uses FeedStreamException.message directly', () {
      const error = FeedStreamException(
        requestId: 'req-1',
        message: 'HTTP request failed: timeout',
        retriedCount: 0,
      );

      expect(
        normalizeChapterErrorMessage(error),
        'HTTP request failed: timeout',
      );
    });

    test('strips type prefix for generic exceptions', () {
      final error = Exception('network broken');
      expect(normalizeChapterErrorMessage(error), 'network broken');
    });

    test('returns "Unknown error" for empty toString', () {
      expect(normalizeChapterErrorMessage(''), 'Unknown error');
    });

    test('returns full text when no colon present', () {
      expect(normalizeChapterErrorMessage('simple error'), 'simple error');
    });
  });

  group('ChapterLoadState', () {
    test('ChapterIdle is sealed subtype', () {
      const state = ChapterIdle();
      expect(state, isA<ChapterLoadState>());
    });

    test('ChapterLoading is sealed subtype', () {
      const state = ChapterLoading();
      expect(state, isA<ChapterLoadState>());
    });

    test('ChapterReady holds paragraphs', () {
      const paragraphs = [
        ParagraphContentTitle(text: 'Title'),
        ParagraphContentText(content: 'Body'),
      ];
      const state = ChapterReady(paragraphs);
      expect(state.paragraphs, hasLength(2));
    });

    test('ChapterError holds error and message', () {
      final error = Exception('fail');
      final state = ChapterError(error: error, message: 'fail');
      expect(state.error, same(error));
      expect(state.message, 'fail');
    });
  });

  group('ChapterSlot', () {
    test('initial state is idle', () {
      const slot = ChapterSlot(
        chapterId: 'c1',
        chapterIndex: 0,
        state: ChapterIdle(),
      );

      expect(slot.isLoading, isFalse);
      expect(slot.isReady, isFalse);
      expect(slot.isError, isFalse);
      expect(slot.paragraphs, isNull);
      expect(slot.error, isNull);
      expect(slot.errorMessage, isNull);
    });

    test('loading state', () {
      const slot = ChapterSlot(
        chapterId: 'c1',
        chapterIndex: 0,
        state: ChapterLoading(),
      );

      expect(slot.isLoading, isTrue);
      expect(slot.isReady, isFalse);
      expect(slot.isError, isFalse);
    });

    test('ready state with paragraphs', () {
      const slot = ChapterSlot(
        chapterId: 'c1',
        chapterIndex: 0,
        state: ChapterReady([
          ParagraphContentTitle(text: 'Title'),
          ParagraphContentText(content: 'Body'),
        ]),
      );

      expect(slot.isReady, isTrue);
      expect(slot.isLoading, isFalse);
      expect(slot.isError, isFalse);
      expect(slot.paragraphs, hasLength(2));
      expect(slot.error, isNull);
    });

    test('error state', () {
      final error = Exception('fetch failed');
      final slot = ChapterSlot(
        chapterId: 'c1',
        chapterIndex: 0,
        state: ChapterError(
          error: error,
          message: normalizeChapterErrorMessage(error),
        ),
      );

      expect(slot.isError, isTrue);
      expect(slot.isLoading, isFalse);
      expect(slot.isReady, isFalse);
      expect(slot.paragraphs, isNull);
      expect(slot.error, same(error));
      expect(slot.errorMessage, 'fetch failed');
    });

    test('copyWith creates new instance with updated fields', () {
      const original = ChapterSlot(
        chapterId: 'c1',
        chapterIndex: 0,
        state: ChapterLoading(),
      );

      final updated = original.copyWith(
        state: const ChapterReady([ParagraphContentText(content: 'Hello')]),
      );

      expect(updated.chapterId, 'c1');
      expect(updated.chapterIndex, 0);
      expect(updated.isReady, isTrue);
      expect(updated.paragraphs, hasLength(1));

      // Original is unchanged.
      expect(original.isLoading, isTrue);
    });

    test('copyWith preserves unspecified fields', () {
      const original = ChapterSlot(
        chapterId: 'c1',
        chapterIndex: 0,
        state: ChapterLoading(),
        requestId: 'req-1',
      );

      final updated = original.copyWith(state: const ChapterReady([]));

      expect(updated.requestId, 'req-1');
    });
  });

  group('ReaderMode', () {
    test('has two values', () {
      expect(ReaderMode.values, hasLength(2));
      expect(ReaderMode.values, contains(ReaderMode.verticalScroll));
      expect(ReaderMode.values, contains(ReaderMode.horizontalPaging));
    });
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:langhuan/features/bookshelf/widgets/reader_chapter_window.dart';
import 'package:langhuan/features/bookshelf/widgets/reader_types.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/src/rust/api/types.dart';

List<ChapterInfoModel> _chapters(int count) => [
  for (var i = 0; i < count; i++) ChapterInfoModel(id: 'c$i', title: 'C$i'),
];

List<ParagraphContent> _paragraphs(String chapterId) => [
  ParagraphContent_Text(
    id: ParagraphId.id('${chapterId}_p1'),
    content: 'text one of $chapterId',
  ),
  ParagraphContent_Text(
    id: ParagraphId.id('${chapterId}_p2'),
    content: 'text two of $chapterId',
  ),
];

Future<List<ParagraphContent>> _immediateLoader(
  String chapterId, {
  bool forceRefresh = false,
}) async {
  return _paragraphs(chapterId);
}

/// Loader that records every call and can fail for selected chapters.
class _RecordingLoader {
  _RecordingLoader({this.failingChapters = const {}});

  final Set<String> failingChapters;
  final calls = <String>[];
  final forcedCalls = <String>[];

  Future<List<ParagraphContent>> call(
    String chapterId, {
    bool forceRefresh = false,
  }) async {
    calls.add(chapterId);
    if (forceRefresh) forcedCalls.add(chapterId);
    if (failingChapters.contains(chapterId)) {
      throw Exception('load failed: $chapterId');
    }
    return _paragraphs(chapterId);
  }
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  group('initial window', () {
    test('covers anchor-1..anchor+1 in the middle of the book', () {
      final window = ReaderChapterWindow(
        chapters: _chapters(6),
        anchorChapterId: 'c2',
        loader: _immediateLoader,
      );

      expect(window.windowChapterIds, ['c1', 'c2', 'c3']);
      expect(window.anchorChapterId, 'c2');
      expect(window.hasChapterAbove, isTrue);
      expect(window.hasChapterBelow, isTrue);
    });

    test('clamps at the book start', () {
      final window = ReaderChapterWindow(
        chapters: _chapters(6),
        anchorChapterId: 'c0',
        loader: _immediateLoader,
      );

      expect(window.windowChapterIds, ['c0', 'c1']);
      expect(window.hasChapterAbove, isFalse);
    });

    test('clamps at the book end', () {
      final window = ReaderChapterWindow(
        chapters: _chapters(6),
        anchorChapterId: 'c5',
        loader: _immediateLoader,
      );

      expect(window.windowChapterIds, ['c4', 'c5']);
      expect(window.hasChapterBelow, isFalse);
    });

    test('loads all window members', () async {
      final window = ReaderChapterWindow(
        chapters: _chapters(6),
        anchorChapterId: 'c2',
        loader: _immediateLoader,
      );
      await _flush();

      expect(window.stateOf('c1'), isA<ChapterLoaded>());
      expect(window.stateOf('c2'), isA<ChapterLoaded>());
      expect(window.stateOf('c3'), isA<ChapterLoaded>());
      expect(window.paragraphsOf('c2')!.length, 2);
    });
  });

  group('expansion', () {
    test('expandBelow grows the window and loads the chapter', () async {
      final loader = _RecordingLoader();
      final window = ReaderChapterWindow(
        chapters: _chapters(8),
        anchorChapterId: 'c2',
        loader: loader.call,
      );
      await _flush();

      window.expandBelow();
      expect(window.windowChapterIds, ['c1', 'c2', 'c3', 'c4']);
      await _flush();

      expect(window.stateOf('c4'), isA<ChapterLoaded>());
      expect(loader.calls, contains('c4'));
    });

    test('expandAbove grows the window upward', () async {
      final window = ReaderChapterWindow(
        chapters: _chapters(8),
        anchorChapterId: 'c2',
        loader: _immediateLoader,
      );
      await _flush();

      window.expandAbove();
      expect(window.windowChapterIds, ['c0', 'c1', 'c2', 'c3']);
      await _flush();

      expect(window.stateOf('c0'), isA<ChapterLoaded>());
      expect(window.hasChapterAbove, isFalse);
    });

    test('expandAbove is a no-op at the book start', () async {
      final loader = _RecordingLoader();
      final window = ReaderChapterWindow(
        chapters: _chapters(3),
        anchorChapterId: 'c0',
        loader: loader.call,
      );
      await _flush();
      loader.calls.clear();

      window.expandAbove();
      expect(window.windowChapterIds, ['c0', 'c1']);
      expect(loader.calls, isEmpty);
    });

    test('concurrent expansion is deduplicated', () async {
      final loader = _RecordingLoader();
      final window = ReaderChapterWindow(
        chapters: _chapters(8),
        anchorChapterId: 'c2',
        loader: loader.call,
      );
      await _flush();
      loader.calls.clear();

      window.expandBelow();
      window.expandBelow();
      window.expandBelow();
      await _flush();

      expect(loader.calls.where((c) => c == 'c4').length, 1);
      expect(window.windowChapterIds, ['c1', 'c2', 'c3', 'c4']);
    });
  });

  group('failures', () {
    test('failed loads surface as errors and retry recovers', () async {
      final loader = _RecordingLoader(failingChapters: {'c3'});
      final window = ReaderChapterWindow(
        chapters: _chapters(6),
        anchorChapterId: 'c2',
        loader: loader.call,
      );
      await _flush();

      final error = window.stateOf('c3');
      expect(error, isA<ChapterLoadError>());
      expect((error as ChapterLoadError).error.toString(), contains('c3'));

      loader.failingChapters.clear();
      window.retry('c3');
      await _flush();

      expect(window.stateOf('c3'), isA<ChapterLoaded>());
    });
  });

  group('jumpTo', () {
    test('resets the window around the target', () async {
      final window = ReaderChapterWindow(
        chapters: _chapters(10),
        anchorChapterId: 'c2',
        loader: _immediateLoader,
      );
      await _flush();

      window.jumpTo('c7');
      expect(window.windowChapterIds, ['c6', 'c7', 'c8']);
      expect(window.anchorChapterId, 'c7');
      await _flush();

      expect(window.stateOf('c6'), isA<ChapterLoaded>());
      expect(window.stateOf('c7'), isA<ChapterLoaded>());
      expect(window.stateOf('c8'), isA<ChapterLoaded>());
    });

    test('reuses cached chapters without loading again', () async {
      final loader = _RecordingLoader();
      final window = ReaderChapterWindow(
        chapters: _chapters(10),
        anchorChapterId: 'c2',
        loader: loader.call,
      );
      await _flush();
      loader.calls.clear();

      window.jumpTo('c1');
      await _flush();

      expect(window.windowChapterIds, ['c0', 'c1', 'c2']);
      // c1/c2 came from cache; only c0 is new.
      expect(loader.calls, ['c0']);
      expect(window.stateOf('c0'), isA<ChapterLoaded>());
    });
  });

  group('maintainAround', () {
    test('re-anchors when the active chapter drifts away', () {
      final window = ReaderChapterWindow(
        chapters: _chapters(20),
        anchorChapterId: 'c5',
        loader: _immediateLoader,
      );

      WindowReanchor? reanchor;
      window.maintainAround('c9', onReanchor: (r) => reanchor = r);

      expect(reanchor, isNotNull);
      expect(reanchor!.oldAnchorChapterId, 'c5');
      expect(reanchor!.newAnchorChapterId, 'c9');
      expect(window.anchorChapterId, 'c9');
    });

    test('does not re-anchor while the active chapter is near', () {
      final window = ReaderChapterWindow(
        chapters: _chapters(20),
        anchorChapterId: 'c5',
        loader: _immediateLoader,
      );

      var reanchored = false;
      window.maintainAround('c7', onReanchor: (_) => reanchored = true);

      expect(reanchored, isFalse);
      expect(window.anchorChapterId, 'c5');
    });

    test('trims the far end down to the cap', () async {
      final window = ReaderChapterWindow(
        chapters: _chapters(40),
        anchorChapterId: 'c5',
        loader: _immediateLoader,
        maxWindowChapters: 4,
      );
      // Grow the window well past the cap.
      for (var i = 0; i < 6; i++) {
        window.expandBelow();
        await _flush();
      }
      for (var i = 0; i < 6; i++) {
        window.expandAbove();
        await _flush();
      }
      expect(window.windowChapterIds.length, greaterThan(4));

      window.maintainAround('c5');

      expect(window.windowChapterIds.length, lessThanOrEqualTo(4));
      // Active chapter and its neighbors stay.
      expect(window.windowChapterIds, contains('c5'));
      expect(window.windowChapterIds, contains('c6'));
    });

    test('never trims visible chapters or the anchor', () async {
      final window = ReaderChapterWindow(
        chapters: _chapters(40),
        anchorChapterId: 'c5',
        loader: _immediateLoader,
        maxWindowChapters: 3,
      );
      for (var i = 0; i < 6; i++) {
        window.expandBelow();
        window.expandAbove();
        await _flush();
      }

      window.maintainAround(
        'c5',
        visibleChapterIds: {'c1', 'c2', 'c3', 'c4', 'c5', 'c6'},
      );

      expect(window.windowChapterIds, containsAll(['c1', 'c2', 'c3', 'c4']));
      expect(window.anchorChapterId, 'c5');
    });
  });

  group('reload', () {
    test('reload drops the cache and fetches fresh content', () async {
      final loader = _RecordingLoader();
      final window = ReaderChapterWindow(
        chapters: _chapters(6),
        anchorChapterId: 'c2',
        loader: loader.call,
      );
      await _flush();
      loader.calls.clear();

      await window.reload('c2', forceRefresh: true);
      await _flush();

      expect(loader.forcedCalls, ['c2']);
      expect(window.stateOf('c2'), isA<ChapterLoaded>());
    });

    test('reloadWindow re-fetches every window member', () async {
      final loader = _RecordingLoader();
      final window = ReaderChapterWindow(
        chapters: _chapters(6),
        anchorChapterId: 'c2',
        loader: loader.call,
      );
      await _flush();
      loader.calls.clear();

      window.reloadWindow();
      await _flush();

      expect(loader.calls, containsAll(['c1', 'c2', 'c3']));
    });
  });

  group('setChapters', () {
    test('replaces the chapter list and re-anchors', () async {
      final window = ReaderChapterWindow(
        chapters: _chapters(6),
        anchorChapterId: 'c2',
        loader: _immediateLoader,
      );
      await _flush();

      window.setChapters(_chapters(4), 'c3');
      expect(window.windowChapterIds, ['c2', 'c3']);
      await _flush();

      expect(window.stateOf('c2'), isA<ChapterLoaded>());
    });
  });
}

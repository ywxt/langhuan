import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:langhuan/features/bookshelf/widgets/reader_core.dart';
import 'package:langhuan/features/bookshelf/widgets/reader_types.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/src/rust/api/types.dart';

List<ParagraphContent> _paragraphs(String chapterId) {
  return [
    ParagraphContent_Text(
      id: ParagraphId.id('${chapterId}_p1'),
      content: 'content $chapterId',
    ),
  ];
}

List<ChapterInfoModel> _chapters(List<String> ids) {
  return ids
      .map((id) => ChapterInfoModel(id: id, title: 'Chapter $id'))
      .toList();
}

void main() {
  test('initCenter loads center and adjacent slots', () async {
    final core = ReaderCore(
      loader: (chapterId) async => _paragraphs(chapterId),
      normalizeError: (e) => e.toString(),
    );

    core.setSource(
      feedId: 'f',
      bookId: 'b',
      chapters: _chapters(['c1', 'c2', 'c3']),
      initialChapterId: 'c2',
    );

    await core.initCenter();
    await Future<void>.delayed(Duration.zero);

    expect(core.centerReady, isTrue);
    expect(core.centerSlot, isA<ChapterLoaded>());
    expect(core.prevSlot, isA<ChapterLoaded>());
    expect(core.nextSlot, isA<ChapterLoaded>());
  });

  test('stale async results do not overwrite active generation', () async {
    final c1Completer = Completer<List<ParagraphContent>>();
    final c2Completer = Completer<List<ParagraphContent>>();

    Future<List<ParagraphContent>> loader(String chapterId) {
      if (chapterId == 'c1') return c1Completer.future;
      if (chapterId == 'c2') return c2Completer.future;
      return Future.value(_paragraphs(chapterId));
    }

    final core = ReaderCore(
      loader: loader,
      normalizeError: (e) => e.toString(),
    );

    core.setSource(
      feedId: 'f',
      bookId: 'b',
      chapters: _chapters(['c1', 'c2']),
      initialChapterId: 'c1',
    );
    final firstInit = core.initCenter();

    core.setSource(
      feedId: 'f',
      bookId: 'b',
      chapters: _chapters(['c1', 'c2']),
      initialChapterId: 'c2',
      clearCache: false,
    );
    final secondInit = core.initCenter();

    c2Completer.complete(_paragraphs('c2'));
    await secondInit;

    c1Completer.complete(_paragraphs('c1'));
    await firstInit;

    expect(core.centerChapterId, 'c2');
    expect(core.centerSlot, isA<ChapterLoaded>());
    expect(core.cachedParagraphs('c2'), isNotNull);
  });

  test('cache eviction keeps window chapters under max size', () async {
    final core = ReaderCore(
      loader: (chapterId) async => _paragraphs(chapterId),
      normalizeError: (e) => e.toString(),
    );

    core.setSource(
      feedId: 'f',
      bookId: 'b',
      chapters: _chapters(['c1', 'c2', 'c3', 'c4', 'c5', 'c6', 'c7']),
      initialChapterId: 'c3',
    );

    await core.initCenter();
    await core.jumpTo(chapterId: 'c5');
    await Future<void>.delayed(Duration.zero);

    expect(core.cacheSize <= 5, isTrue);
    expect(core.hasCachedChapter('c5'), isTrue);
  });

  test('adjacent dynamic loading does not change current anchor', () async {
    final prevCompleter = Completer<List<ParagraphContent>>();
    final nextCompleter = Completer<List<ParagraphContent>>();

    Future<List<ParagraphContent>> loader(String chapterId) {
      if (chapterId == 'c1') return prevCompleter.future;
      if (chapterId == 'c3') return nextCompleter.future;
      return Future.value(_paragraphs(chapterId));
    }

    final core = ReaderCore(
      loader: loader,
      normalizeError: (e) => e.toString(),
    );

    core.setSource(
      feedId: 'f',
      bookId: 'b',
      chapters: _chapters(['c1', 'c2', 'c3']),
      initialChapterId: 'c2',
    );

    await core.initCenter();
    await core.jumpTo(
      chapterId: 'c2',
      paragraphId: 'c2_p1',
      paragraphOffset: 88,
    );

    final beforeChapter = core.centerChapterId;
    final beforeAnchor = core.pendingJumpParagraphId;
    final beforeOffset = core.pendingJumpParagraphOffset;
    final beforeCenterSlot = core.centerSlot;

    prevCompleter.complete(_paragraphs('c1'));
    nextCompleter.complete(_paragraphs('c3'));
    await Future<void>.delayed(Duration.zero);

    expect(core.centerChapterId, beforeChapter);
    expect(core.pendingJumpParagraphId, beforeAnchor);
    expect(core.pendingJumpParagraphOffset, beforeOffset);
    expect(core.centerSlot, same(beforeCenterSlot));
  });
}

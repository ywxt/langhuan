import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/listening/listening_controller.dart';
import 'package:langhuan/features/bookshelf/listening/local_speech_engine.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/src/rust/api/listening.dart';
import 'package:langhuan/src/rust/api/types.dart';
import '../feeds/fake_feed_service.dart';

class _Service extends FakeFeedService {
  final saved = <ListeningPosition>[];
  ListeningPosition? restore;
  bool failSecondChapter = false;
  String firstText = '第一句。第二句。';
  @override
  Future<List<ChapterInfoModel>> chapters({
    required String feedId,
    required String bookId,
    bool forceRefresh = false,
  }) async => const [
    ChapterInfoModel(id: 'c1', title: 'One'),
    ChapterInfoModel(id: 'c2', title: 'Two'),
  ];
  @override
  Future<List<ParagraphContent>> paragraphs({
    required String feedId,
    required String bookId,
    required String chapterId,
    bool forceRefresh = false,
  }) async {
    if (failSecondChapter && chapterId == 'c2') {
      throw StateError('chapter failed');
    }
    return [
      ParagraphContent.text(
        id: const ParagraphId(
          original: OriginalParagraphId.source('839'),
          path: [],
        ),
        content: chapterId == 'c1' ? firstText : '下一章。',
      ),
    ];
  }

  @override
  Future<ListeningPosition?> listeningPosition(
    String feedId,
    String bookId,
  ) async => restore;
  @override
  Future<void> saveListeningPosition(
    String feedId,
    String bookId,
    ListeningPosition position,
  ) async {
    saved.add(position);
  }
}

class _Engine implements SpeechEngine {
  final spoken = <String>[];
  Completer<void>? pending;
  @override
  Future<List<LocalVoice>> voices() async => const [
    LocalVoice('offline', 'Offline', 'zh-CN'),
  ];
  @override
  Future<void> speak(String text, LocalVoice voice, double rate) {
    spoken.add(text);
    pending = Completer<void>();
    return pending!.future;
  }

  void finish() {
    pending?.complete();
    pending = null;
  }

  @override
  Future<void> stop() async {
    finish();
  }
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  test('chunks preserve exact text and never cut surrogate pairs', () {
    final text = '${'字' * 239}😀。尾句！';
    final chunks = speechChunks(text).toList();
    expect(chunks.map((c) => text.substring(c.start, c.end)).join(), text);
    for (final c in chunks) {
      expect(text.substring(c.start, c.end).runes.contains(0xfffd), isFalse);
      expect(c.end - c.start, lessThanOrEqualTo(240));
    }
  });
  test('pause in a later chunk resumes from the paragraph beginning', () async {
    final service = _Service()..firstText = '段首。${'字' * 300}。段尾。';
    final engine = _Engine();
    final controller = ListeningController(service, engine);
    addTearDown(controller.dispose);
    await controller.start(feedId: 'f', bookId: 'b', chapterId: 'c1');
    await _flush();
    expect(engine.spoken.first, '段首。');
    engine.finish();
    await _flush();
    expect(engine.spoken, hasLength(2));
    expect(
      service.saved,
      hasLength(1),
      reason: 'chunks do not create position writes',
    );
    final id = controller.paragraphId;
    await controller.pause();
    expect(service.saved.last.paragraphId, id);
    expect(controller.status, ListeningStatus.paused);
    controller.resume();
    await _flush();
    expect(engine.spoken.last, '段首。');
    expect(controller.paragraphId, id);
  });
  test(
    'a saved position restores the paragraph without a text revision',
    () async {
      final service = _Service()
        ..restore = ListeningPosition(
          chapterId: 'c1',
          paragraphId: const ParagraphId(
            original: OriginalParagraphId.source('839'),
            path: [],
          ).toStringValue(),
        );
      final engine = _Engine();
      final controller = ListeningController(service, engine);
      addTearDown(controller.dispose);
      await controller.start(feedId: 'f', bookId: 'b', chapterId: 'c1');
      await _flush();
      expect(controller.paragraphId, service.restore!.paragraphId);
      expect(engine.spoken.first, '第一句。第二句。');
    },
  );
  test(
    'chapter failure stops at failed chapter instead of skipping it',
    () async {
      final service = _Service()..failSecondChapter = true;
      final engine = _Engine();
      final controller = ListeningController(service, engine);
      addTearDown(controller.dispose);
      await controller.start(feedId: 'f', bookId: 'b', chapterId: 'c1');
      await _flush();
      engine.finish();
      await _flush();
      expect(controller.status, ListeningStatus.error);
      expect(engine.spoken, hasLength(1));
      expect(service.saved.last.chapterId, 'c1');
      controller.resume();
      await _flush();
      expect(controller.status, ListeningStatus.error);
    },
  );
  test('sleep timer pauses the current utterance', () async {
    final engine = _Engine();
    final controller = ListeningController(_Service(), engine);
    addTearDown(controller.dispose);
    await controller.start(feedId: 'f', bookId: 'b', chapterId: 'c1');
    await _flush();
    controller.setSleepTimer(const Duration(milliseconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(controller.status, ListeningStatus.paused);
  });
}

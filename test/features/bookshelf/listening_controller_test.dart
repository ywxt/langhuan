import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/listening/listening_controller.dart';
import 'package:langhuan/features/bookshelf/listening/local_speech_engine.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/src/rust/api/types.dart';
import '../feeds/fake_feed_service.dart';

class _Service extends FakeFeedService {
  final saved = <ReadingProgressModel>[];
  ReadingProgressModel? restore;
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
  Future<ReadingProgressModel?> getReadingProgress({
    required String feedId,
    required String bookId,
  }) async => restore;
  @override
  Future<void> setReadingProgress({
    required String feedId,
    required String bookId,
    required String chapterId,
    required String paragraphId,
    int paragraphCharOffset = 0,
    required int updatedAtMs,
  }) async {
    final progress = ReadingProgressModel(
      feedId: feedId,
      bookId: bookId,
      chapterId: chapterId,
      paragraphId: paragraphId,
      paragraphCharOffset: paragraphCharOffset,
      updatedAtMs: updatedAtMs,
    );
    restore = progress;
    saved.add(progress);
  }
}

class _Engine implements SpeechEngine {
  final spoken = <String>[];
  LocalVoice? spokenVoice;
  int voiceRequests = 0;
  Completer<List<LocalVoice>>? voiceResult;
  Completer<void>? pending;
  List<LocalVoice> availableVoices = const [
    LocalVoice('offline', 'Offline', 'zh-CN'),
  ];
  @override
  Future<List<LocalVoice>> voices() async {
    voiceRequests++;
    return voiceResult != null ? await voiceResult!.future : availableVoices;
  }

  @override
  Future<void> speak(String text, LocalVoice voice, double rate) {
    spoken.add(text);
    spokenVoice = voice;
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
  test(
    'voices can be selected before playback without reading or speaking',
    () async {
      final service = _Service();
      final engine = _Engine()
        ..availableVoices = const [
          LocalVoice('zh', 'Chinese', 'zh-CN'),
          LocalVoice('zh', 'Chinese', 'zh-HK'),
        ];
      final controller = ListeningController(service, engine);
      addTearDown(controller.dispose);
      await controller.loadVoices();
      expect(controller.status, ListeningStatus.idle);
      expect(controller.feedId, isEmpty);
      expect(service.saved, isEmpty);
      expect(engine.spoken, isEmpty);
      await controller.configure(voice: controller.voices.last);
      await controller.start(feedId: 'f', bookId: 'b', chapterId: 'c1');
      await _flush();
      expect(engine.spokenVoice!.locale, 'zh-HK');
      expect(engine.voiceRequests, 1);
      await controller.stop();
    },
  );

  test(
    'concurrent voice preparation shares one request and survives disposal',
    () async {
      final engine = _Engine()..voiceResult = Completer<List<LocalVoice>>();
      final controller = ListeningController(_Service(), engine);
      final first = controller.loadVoices();
      final second = controller.loadVoices();
      expect(identical(first, second), isTrue);
      expect(controller.voicesLoading, isTrue);
      expect(engine.voiceRequests, 1);
      controller.dispose();
      engine.voiceResult!.complete(engine.availableVoices);
      await first;
    },
  );

  test(
    'failed voice preparation can retry without changing playback status',
    () async {
      final engine = _Engine()..availableVoices = [];
      final controller = ListeningController(_Service(), engine);
      addTearDown(controller.dispose);
      await controller.loadVoices();
      expect(controller.voicesError, isNotNull);
      expect(controller.status, ListeningStatus.idle);
      engine.availableVoices = const [LocalVoice('zh', 'Chinese', 'zh-CN')];
      await controller.loadVoices();
      expect(controller.voicesError, isNull);
      expect(controller.voice!.locale, 'zh-CN');
      expect(engine.spoken, isEmpty);
    },
  );
  test(
    'resume uses manual reading progress and stop does not overwrite it',
    () async {
      final service = _Service();
      final engine = _Engine();
      final controller = ListeningController(service, engine);
      addTearDown(controller.dispose);
      await controller.start(feedId: 'f', bookId: 'b', chapterId: 'c1');
      await _flush();
      await controller.pause();
      await service.setReadingProgress(
        feedId: 'f',
        bookId: 'b',
        chapterId: 'c2',
        paragraphId: service.saved.last.paragraphId,
        paragraphCharOffset: 12,
        updatedAtMs: 2,
      );
      final count = service.saved.length;
      await controller.stop();
      expect(service.saved, hasLength(count));
      expect(service.restore!.chapterId, 'c2');
      expect(service.restore!.paragraphCharOffset, 12);
      controller.resume();
      await _flush();
      expect(controller.chapterId, 'c2');
      expect(engine.spoken.last, '下一章。');
      expect(service.saved.last.paragraphCharOffset, 0);
      await controller.stop();
    },
  );
  test(
    'reloading voices preserves the selected locale for a shared name',
    () async {
      final engine = _Engine()
        ..availableVoices = const [
          LocalVoice('zh', 'Chinese', 'zh-CN'),
          LocalVoice('zh', 'Chinese', 'zh-HK'),
        ];
      final controller = ListeningController(_Service(), engine);
      addTearDown(controller.dispose);
      await controller.start(feedId: 'f', bookId: 'b', chapterId: 'c1');
      await _flush();
      await controller.pause();
      await controller.configure(voice: controller.voices.last);
      await controller.start(feedId: 'f', bookId: 'b', chapterId: 'c1');
      await _flush();
      expect(controller.voice!.locale, 'zh-HK');
      await controller.stop();
    },
  );
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
      hasLength(2),
      reason: 'only chapter and paragraph entry write progress, not chunks',
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
    'shared reading progress restores the paragraph without a separate position',
    () async {
      final service = _Service()
        ..restore = ReadingProgressModel(
          feedId: 'f',
          bookId: 'b',
          updatedAtMs: 1,
          chapterId: 'c1',
          paragraphId: const ParagraphId(
            original: OriginalParagraphId.source('839'),
            path: [],
          ).toStringValue(),
        );
      final engine = _Engine();
      final controller = ListeningController(service, engine);
      addTearDown(controller.dispose);
      await controller.start(feedId: 'f', bookId: 'b');
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
      expect(service.saved.last.chapterId, 'c2');
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

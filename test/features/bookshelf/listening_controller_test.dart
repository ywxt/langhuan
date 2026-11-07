import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';
import 'package:langhuan/features/bookshelf/listening/listening_audio_handler.dart';
import 'package:langhuan/features/feeds/feed_providers.dart';
import 'package:langhuan/features/transformers/transformer_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/listening/listening_controller.dart';
import 'package:langhuan/features/bookshelf/listening/listening_providers.dart';
import 'package:langhuan/features/bookshelf/listening/local_speech_engine.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/src/rust/api/types.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../feeds/fake_feed_service.dart';

class _Service extends FakeFeedService {
  final saved = <ReadingProgressModel>[];
  ReadingProgressModel? restore;
  bool failSecondChapter = false;
  String firstText = '第一句。第二句。';
  final chapterCalls = <String>[];
  final paragraphCalls = <String>[];
  @override
  Future<List<ChapterInfoModel>> chapters({
    required String feedId,
    required String bookId,
    bool forceRefresh = false,
  }) async {
    chapterCalls.add(bookId);
    return const [
      ChapterInfoModel(id: 'c1', title: 'One'),
      ChapterInfoModel(id: 'c2', title: 'Two'),
    ];
  }

  ParagraphContent text(String sourceId, String content) =>
      ParagraphContent.text(
        id: ParagraphId(
          original: OriginalParagraphId.source(sourceId),
          path: const [],
        ),
        content: content,
      );

  @override
  Future<List<ParagraphContent>> paragraphs({
    required String feedId,
    required String bookId,
    required String chapterId,
    bool forceRefresh = false,
  }) async {
    paragraphCalls.add(chapterId);
    if (failSecondChapter && chapterId == 'c2') {
      throw StateError('chapter failed');
    }
    return [text('839', chapterId == 'c1' ? firstText : '下一章。')];
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
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'rapid configuration keeps playback running with the last rate',
    () async {
      final engine = _Engine();
      final controller = ListeningController(_Service(), engine);
      addTearDown(controller.dispose);
      await controller.start(feedId: 'f', bookId: 'b', chapterId: 'c1');
      await _flush();
      final first = controller.configure(rate: 1.25);
      final second = controller.configure(rate: 1.5);
      await Future.wait([first, second]);
      await _flush();
      expect(controller.status, ListeningStatus.playing);
      expect(controller.rate, 1.5);
      expect(engine.spoken, hasLength(2));
    },
  );

  test('stop cancels an in-flight configuration without restarting', () async {
    final engine = _Engine();
    final controller = ListeningController(_Service(), engine);
    addTearDown(controller.dispose);
    await controller.start(feedId: 'f', bookId: 'b', chapterId: 'c1');
    await _flush();
    final update = controller.configure(rate: 1.5);
    await controller.stop();
    await update;
    await _flush();
    expect(controller.status, ListeningStatus.idle);
    expect(engine.spoken, hasLength(1));
  });

  test('completed playback keeps the chapter progress at one', () async {
    final engine = _Engine();
    final controller = ListeningController(_Service(), engine);
    addTearDown(controller.dispose);
    await controller.start(feedId: 'f', bookId: 'b', chapterId: 'c1');
    await _flush();
    engine.finish();
    await _flush();
    engine.finish();
    await _flush();
    expect(controller.status, ListeningStatus.completed);
    expect(controller.chapterProgress, 1);
  });

  for (final playing in [false, true]) {
    test(
      'content invalidation reloads current and prefetched chapters, playing=$playing',
      () async {
        final service = _Service();
        final engine = _Engine();
        final controller = ListeningController(service, engine);
        addTearDown(controller.dispose);
        await controller.start(feedId: 'f', bookId: 'b', chapterId: 'c1');
        await _flush();
        if (!playing) await controller.pause();
        service.firstText = '新的正文。';
        await controller.invalidateContent();
        if (!playing) {
          expect(controller.status, ListeningStatus.paused);
          expect(engine.spoken, hasLength(1));
          await controller.resume();
        }
        await _flush();
        expect(engine.spoken.last, '新的正文。');
        expect(service.chapterCalls, hasLength(1));
        expect(service.paragraphCalls, ['c1', 'c2', 'c1', 'c2']);
        expect(service.restore!.paragraphId, controller.paragraphId);
      },
    );
  }

  testWidgets(
    'background lifecycle does not pause and transformer updates reload speech',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final service = _Service();
      final engine = _Engine();
      final settings = _TransformerSettings();
      final container = ProviderContainer(
        overrides: [
          feedServiceProvider.overrideWithValue(service),
          listeningBackgroundPlaybackProvider.overrideWithValue(_Background()),
          speechEngineProvider.overrideWithValue(engine),
          transformerSettingsProvider.overrideWith(() => settings),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(listeningControllerProvider);
      await container.read(transformerSettingsProvider.future);
      await controller.start(feedId: 'f', bookId: 'b', chapterId: 'c1');
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(controller.status, ListeningStatus.playing);
      service.firstText = '新配置正文。';
      settings.changeRules();
      await tester.pump();
      await tester.pump();
      expect(engine.spoken.last, '新配置正文。');
      expect(controller.status, ListeningStatus.playing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await controller.stop();
      await tester.pump();
    },
  );

  test(
    'system media controls share the UI controller and paragraph progress',
    () async {
      final service = _Service();
      final engine = _Engine();
      final controller = ListeningController(service, engine);
      addTearDown(controller.dispose);
      final handler = ListeningAudioHandler(controller);
      addTearDown(handler.dispose);
      await controller.start(
        feedId: 'f',
        bookId: 'b',
        chapterId: 'c1',
        bookTitle: 'Book',
      );
      await _flush();
      expect(handler.mediaItem.value!.title, 'One');
      expect(handler.playbackState.value.playing, isTrue);
      await handler.pause();
      expect(controller.status, ListeningStatus.paused);
      expect(handler.playbackState.value.playing, isFalse);
      await handler.play();
      await _flush();
      expect(controller.status, ListeningStatus.playing);
      engine.finish();
      await _flush();
      expect(handler.mediaItem.value!.title, 'Two');
      expect(service.restore!.chapterId, 'c2');
      engine.finish();
      await _flush();
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.idle,
      );
      expect(handler.playbackState.value.playing, isFalse);
      await handler.stop();
      expect(controller.status, ListeningStatus.idle);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.idle,
      );
    },
  );

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
  test('next chapter is prefetched while the current one plays', () async {
    final service = _Service();
    final engine = _Engine();
    final controller = ListeningController(service, engine);
    addTearDown(controller.dispose);
    await controller.start(feedId: 'f', bookId: 'b', chapterId: 'c1');
    await _flush();
    // The prefetch for c2 was kicked as soon as c1 began speaking.
    expect(service.paragraphCalls, ['c1', 'c2']);
    engine.finish();
    await _flush();
    // c2 came out of the prefetch slot: no second fetch, no gap.
    expect(service.paragraphCalls, ['c1', 'c2']);
    expect(engine.spoken, ['第一句。第二句。', '下一章。']);
    await controller.stop();
  });
  test('resume keeps in-memory chapters and paragraphs', () async {
    final service = _Service();
    final engine = _Engine();
    final controller = ListeningController(service, engine);
    addTearDown(controller.dispose);
    await controller.start(feedId: 'f', bookId: 'b', chapterId: 'c1');
    await _flush();
    await controller.pause();
    controller.resume();
    await _flush();
    // One chapters read, one c1 fetch (plus the c2 prefetch): no refetch.
    expect(service.chapterCalls, hasLength(1));
    expect(service.paragraphCalls, ['c1', 'c2']);
    expect(engine.spoken, ['第一句。第二句。', '第一句。第二句。']);
    await controller.stop();
  });
  test('resume follows manual reading within the same chapter', () async {
    final service = _MultiParagraphService();
    final engine = _Engine();
    final controller = ListeningController(service, engine);
    addTearDown(controller.dispose);
    await controller.start(feedId: 'f', bookId: 'b', chapterId: 'c1');
    await _flush();
    expect(engine.spoken, ['第一段。']);
    await controller.pause();
    await service.setReadingProgress(
      feedId: 'f',
      bookId: 'b',
      chapterId: 'c1',
      paragraphId: const ParagraphId(
        original: OriginalParagraphId.source('840'),
        path: [],
      ).toStringValue(),
      updatedAtMs: 2,
    );
    controller.resume();
    await _flush();
    expect(engine.spoken, ['第一段。', '第二段。']);
    await controller.stop();
  });
  test('sleep at chapter end pauses instead of advancing', () async {
    final service = _Service();
    final engine = _Engine();
    final controller = ListeningController(service, engine);
    addTearDown(controller.dispose);
    controller.setSleepTimer(null, atChapterEnd: true);
    await controller.start(feedId: 'f', bookId: 'b', chapterId: 'c1');
    await _flush();
    engine.finish();
    await _flush();
    expect(controller.status, ListeningStatus.paused);
    expect(controller.sleepAtChapterEnd, isFalse);
    expect(engine.spoken, ['第一句。第二句。']);
    controller.resume();
    await _flush();
    expect(controller.status, ListeningStatus.playing);
    expect(engine.spoken.last, '下一章。');
    await controller.stop();
  });
  test('rate and voice persist across controller instances', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final engine = _Engine()
      ..availableVoices = const [
        LocalVoice('zh', 'Chinese', 'zh-CN'),
        LocalVoice('zh', 'Chinese', 'zh-HK'),
      ];
    final first = ListeningController(_Service(), engine);
    addTearDown(first.dispose);
    await first.loadVoices();
    await first.configure(voice: first.voices.last, rate: 1.5);
    await _drain();
    final second = ListeningController(_Service(), engine);
    addTearDown(second.dispose);
    await _drain();
    expect(second.rate, 1.5);
    await second.loadVoices();
    expect(second.voice!.locale, 'zh-HK');
    // Keep later tests in this isolate free of the mock store.
    SharedPreferences.setMockInitialValues({});
  });
}

class _MultiParagraphService extends _Service {
  @override
  Future<List<ParagraphContent>> paragraphs({
    required String feedId,
    required String bookId,
    required String chapterId,
    bool forceRefresh = false,
  }) async {
    paragraphCalls.add(chapterId);
    if (chapterId != 'c1') return [text('939', '下一章。')];
    return [text('839', '第一段。'), text('840', '第二段。')];
  }
}

/// Pumps the event loop enough for fire-and-forget preference writes.
Future<void> _drain() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _TransformerSettings extends TransformerSettingsNotifier {
  @override
  Future<TransformerSettings> build() async => TransformerSettings();
  void changeRules() {
    state = AsyncData(
      TransformerSettings(
        application: [
          const TransformerEntry(kind: TransformerKind.paragraphIndent),
        ],
      ),
    );
  }
}

class _Background extends ListeningBackgroundPlayback {
  @override
  Future<void> prepare(ListeningController controller) async {}
}

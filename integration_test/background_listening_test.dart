import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:langhuan/features/bookshelf/listening/listening_audio_handler.dart';
import 'package:langhuan/features/bookshelf/listening/listening_controller.dart';
import 'package:langhuan/features/bookshelf/listening/local_speech_engine.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/src/rust/api/types.dart';

/// Offline fixture isolates OS background execution and the real system TTS
/// from source availability. Progress writes and utterances remain observable.
class _Book implements FeedService {
  final saved = <String>[];
  @override
  Future<List<ChapterInfoModel>> chapters({
    required String feedId,
    required String bookId,
    bool forceRefresh = false,
  }) async => const [
    ChapterInfoModel(id: 'c1', title: 'Background chapter'),
    ChapterInfoModel(id: 'c2', title: 'Next chapter'),
  ];
  @override
  Future<List<ParagraphContent>> paragraphs({
    required String feedId,
    required String bookId,
    required String chapterId,
    bool forceRefresh = false,
  }) async => [
    for (var i = 0; i < 4; i++)
      ParagraphContent.text(
        id: ParagraphId(
          original: OriginalParagraphId.source('$i'),
          path: const [],
        ),
        content: '這是後臺聽書測試。手機鎖屏後，應繼續朗讀下一段，並保存閱讀進度。',
      ),
  ];
  @override
  Future<ReadingProgressModel?> getReadingProgress({
    required String feedId,
    required String bookId,
  }) async => null;
  @override
  Future<void> setReadingProgress({
    required String feedId,
    required String bookId,
    required String chapterId,
    required String paragraphId,
    int paragraphCharOffset = 0,
    required int updatedAtMs,
  }) async {
    if (paragraphId.isNotEmpty) saved.add('$chapterId/$paragraphId');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('system TTS continues across paragraphs while backgrounded', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Text('Background listening test')),
      ),
    );
    final book = _Book();
    var backgrounded = false;
    final lifecycle = AppLifecycleListener(
      onPause: () => backgrounded = true,
      onHide: () => backgrounded = true,
    );
    addTearDown(lifecycle.dispose);
    final background = ListeningBackgroundPlayback();
    late final ListeningController controller;
    controller = ListeningController(
      book,
      LocalSpeechEngine(managedAudioSession: true),
      preparePlayback: () => background.prepare(controller),
    );
    addTearDown(() async {
      await controller.stop();
      background.dispose();
      controller.dispose();
    });
    await tester.runAsync(
      () => controller.start(
        feedId: 'fixture',
        bookId: 'book',
        chapterId: 'c1',
        bookTitle: 'Background listening test',
      ),
    );
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (book.saved.isEmpty &&
          controller.active &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    });
    expect(
      controller.status,
      ListeningStatus.playing,
      reason: '${controller.error}',
    );
    final initialCount = book.saved.length;
    // During this real-time window, the host can send KEYCODE_HOME or lock
    // the device. Multiple completed utterances must advance the same progress.
    debugPrint('BACKGROUND_TTS_READY');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 35)),
    );
    expect(
      backgrounded,
      isTrue,
      reason: 'Send HOME or lock the device after BACKGROUND_TTS_READY',
    );
    expect(controller.error, isNull);
    expect(book.saved.length, greaterThan(initialCount));
    debugPrint('BACKGROUND_TTS_ADVANCED=${book.saved.length}');
    // Notification commands control the exact same playback session.
    await background.handler!.pause();
    expect(controller.status, ListeningStatus.paused);
    await background.handler!.play();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 1)),
    );
    expect(controller.active, isTrue, reason: '${controller.error}');
    await background.handler!.stop();
    expect(controller.status, ListeningStatus.idle);
  });
}

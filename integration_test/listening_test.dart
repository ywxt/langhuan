import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:langhuan/features/bookshelf/listening/listening_controller.dart';
import 'package:langhuan/features/bookshelf/listening/listening_panel.dart';
import 'package:langhuan/features/bookshelf/listening/local_speech_engine.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import 'package:langhuan/shared/app_service.dart';
import 'package:langhuan/src/rust/frb_generated.dart';

import 'fixture_feed.dart';

// Control only speech completion; source loading, HTTP, FRB, persistence,
// controller transitions and playback controls use their production code.
class _Speech implements SpeechEngine {
  final spoken = <String>[];
  Completer<void>? pending;

  @override
  Future<List<LocalVoice>> voices() async => const [
    LocalVoice('zh', 'Chinese', 'zh-CN'),
    LocalVoice('zh', 'Chinese', 'zh-HK'),
  ];

  @override
  Future<void> speak(String text, LocalVoice voice, double rate) {
    spoken.add(text);
    return (pending = Completer<void>()).future;
  }

  void finish() {
    final current = pending;
    pending = null;
    current?.complete();
  }

  @override
  Future<void> stop() async => finish();
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Playback did not reach its expected state');
    }
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pump();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('listening controls persist paragraphs, restore and cross chapters', (
    tester,
  ) async {
    await RustLib.init();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var failChapter = false;
    server.listen((request) async {
      if (request.uri.path.startsWith('/paragraphs/')) {
        final second = request.uri.path.endsWith('/2');
        if (failChapter && second) {
          request.response.statusCode = 404;
        } else {
          request.response.write(
            jsonEncode([
              {
                'type': 'title',
                'id': 'heading',
                'text': second ? 'Chapter two.' : 'Chapter one.',
              },
              {
                'type': 'image',
                'id': 'image',
                'url': 'https://example.invalid/unused.png',
              },
              {
                'type': 'text',
                'id': 'p1',
                'content': second ? 'Final paragraph.' : 'First paragraph.',
              },
              if (!second)
                {'type': 'text', 'id': 'p2', 'content': 'Second paragraph.'},
            ]),
          );
        }
      } else {
        request.response.write('2');
      }
      await request.response.close();
    });
    final directory = await Directory.systemTemp.createTemp(
      'langhuan-listening-',
    );
    await AppService.instance.setAppDataDirectory(directory.path);
    final script =
        fixtureFeedScript(
          id: 'listening-fixture',
          name: 'Listening',
          port: server.port,
        ).replaceFirst(
          'return { type: "complete", result: [{ type: "text", content: "Fixture paragraph." }] };',
          '''if (event.response.status !== 200) return FeedError.contentNotFound("Chapter unavailable");
return { type: "complete", result: JSON.parse(DECODER.decode(event.response.body)) };''',
        );
    final file = File('${directory.path}/listening.js')
      ..writeAsStringSync(script);
    final service = FeedService.instance;
    final preview = await service.previewFromFile(file.path);
    await service.installFeed(preview.requestId);
    final speech = _Speech();
    var controller = ListeningController(service, speech);
    addTearDown(() => controller.dispose());

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showListeningPanel(
                  context,
                  controller,
                  onStart: () {
                    unawaited(
                      controller.start(
                        feedId: 'listening-fixture',
                        bookId: '1001',
                      ),
                    );
                  },
                ),
                child: const Text('Open listening'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open listening'));
    await tester.pumpAndSettle();
    expect(controller.status, ListeningStatus.idle);
    expect(speech.spoken, isEmpty);
    await tester.tap(find.byKey(const ValueKey('listening-voice-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'zh-HK'));
    await tester.pumpAndSettle();
    expect(controller.voice!.locale, 'zh-HK');
    expect(speech.spoken, isEmpty);
    expect(
      await service.getReadingProgress(
        feedId: 'listening-fixture',
        bookId: '1001',
      ),
      isNull,
    );
    await tester.tap(find.text('Start listening'));
    await _until(tester, () => speech.spoken.length == 1);
    expect(speech.spoken.single, 'Chapter one.');
    speech.finish();
    await _until(tester, () => speech.spoken.length == 2);
    expect(speech.spoken.last.trim(), 'First paragraph.'); // image skipped
    await tester.tap(find.text('Pause'));
    await _until(tester, () => controller.status == ListeningStatus.paused);
    final paused = await service.getReadingProgress(
      feedId: 'listening-fixture',
      bookId: '1001',
    );
    expect(paragraphIdFromString(paused!.paragraphId)?.sourceId, 'p1');
    final reading = await service.getReadingProgress(
      feedId: 'listening-fixture',
      bookId: '1001',
    );
    expect(reading!.paragraphId, paused.paragraphId);
    expect(reading.paragraphCharOffset, 0);

    // Android engines may reuse "zh" for different locales. The voice
    // picker must show both and select the requested voice without an assertion.
    await tester.tap(find.byKey(const ValueKey('listening-voice-selector')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'zh-HK');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'zh-HK'));
    await tester.pumpAndSettle();
    expect(controller.voice!.locale, 'zh-HK');
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Resume'));
    await _until(tester, () => speech.spoken.length == 3);
    expect(speech.spoken.last.trim(), 'First paragraph.');
    speech.finish();
    await _until(tester, () => speech.spoken.length == 4);
    expect(speech.spoken.last.trim(), 'Second paragraph.');
    await tester.tap(find.byTooltip('Stop listening'));
    await _until(tester, () => controller.status == ListeningStatus.idle);
    await controller.stop();
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    controller = ListeningController(service, speech);
    await controller.start(feedId: 'listening-fixture', bookId: '1001');
    await _until(tester, () => speech.spoken.length == 5);
    expect(speech.spoken.last.trim(), 'Second paragraph.');
    speech.finish();
    await _until(tester, () => speech.spoken.length == 6);
    expect(controller.chapterId, '2');
    expect(speech.spoken.last.trim(), 'Chapter two.');
    speech.finish();
    await _until(tester, () => speech.spoken.length == 7);
    expect(speech.spoken.last.trim(), 'Final paragraph.');
    speech.finish();
    await _until(tester, () => controller.status == ListeningStatus.completed);
    final completed = await service.getReadingProgress(
      feedId: 'listening-fixture',
      bookId: '1001',
    );
    expect(completed!.chapterId, '2');
    expect(paragraphIdFromString(completed.paragraphId)?.sourceId, 'p1');

    failChapter = true;
    await controller.start(
      feedId: 'listening-fixture',
      bookId: 'failure-book',
      chapterId: '2',
    );
    await _until(tester, () => controller.status == ListeningStatus.error);
    expect(controller.error, isNotNull);
    expect(speech.spoken, hasLength(7));
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:langhuan/features/bookshelf/listening/listening_controller.dart';
import 'package:langhuan/features/bookshelf/listening/local_speech_engine.dart';
import 'package:langhuan/features/bookshelf/reader_page.dart';
import 'package:langhuan/features/bookshelf/reader_settings_provider.dart';
import 'package:langhuan/features/bookshelf/widgets/horizontal_reader_view.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import 'package:langhuan/shared/app_service.dart';
import 'package:langhuan/src/rust/frb_generated.dart';
import 'package:langhuan/src/rust/api/types.dart';

import 'fixture_feed.dart';

class _Settings extends ReaderSettingsNotifier {
  _Settings(this.mode);
  final ReaderPageMode mode;
  @override
  ReaderSettingsState build() => ReaderSettingsState(pageMode: mode);
}

class _Speech implements SpeechEngine {
  Completer<void>? pending;
  @override
  Future<List<LocalVoice>> voices() async => const [
    LocalVoice('fixture', 'Fixture', 'en-US'),
  ];
  @override
  Future<void> speak(String text, LocalVoice voice, double rate) =>
      (pending = Completer<void>()).future;
  @override
  Future<void> stop() async => finish();
  void finish() {
    final current = pending;
    pending = null;
    current?.complete();
  }
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Reader did not follow speech');
    }
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pump();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('speech turns pages and scrolls while sharing reading progress', (
    tester,
  ) async {
    await RustLib.init();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      if (request.uri.path.startsWith('/paragraphs/')) {
        request.response.write(
          jsonEncode([
            {
              'type': 'text',
              'id': 'p1',
              'content': List.filled(300, 'A long reading paragraph. ').join(),
            },
            {'type': 'text', 'id': 'p2', 'content': 'Second paragraph.'},
          ]),
        );
      } else {
        request.response.write('1');
      }
      await request.response.close();
    });
    final directory = await Directory.systemTemp.createTemp(
      'langhuan-listening-reader-',
    );
    await AppService.instance.setAppDataDirectory(directory.path);
    final script =
        fixtureFeedScript(
          id: 'listening-reader',
          name: 'Reader',
          port: server.port,
        ).replaceFirst(
          'return { type: "complete", result: [{ type: "text", content: "Fixture paragraph." }] };',
          'return { type: "complete", result: JSON.parse(DECODER.decode(event.response.body)) };',
        );
    final file = File('${directory.path}/reader.js')..writeAsStringSync(script);
    final service = FeedService.instance;
    final preview = await service.previewFromFile(file.path);
    await service.installFeed(preview.requestId);
    final content = await service.paragraphs(
      feedId: 'listening-reader',
      bookId: '1001',
      chapterId: '1',
    );
    final first = (content.first as ParagraphContent_Text).id.toStringValue();
    final second = (content.last as ParagraphContent_Text).id.toStringValue();

    for (final mode in ReaderPageMode.values) {
      await service.setReadingProgress(
        feedId: 'listening-reader',
        bookId: '1001',
        chapterId: '1',
        paragraphId: first,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      final speech = _Speech();
      final controller = ListeningController(service, speech);
      final container = ProviderContainer(
        overrides: [
          listeningControllerProvider.overrideWithValue(controller),
          readerSettingsProvider.overrideWith(() => _Settings(mode)),
        ],
      );
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const ReaderPage(
                feedId: 'listening-reader',
                bookId: '1001',
                chapterId: '1',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _until(
          tester,
          () => find
              .textContaining('A long reading paragraph.')
              .evaluate()
              .isNotEmpty,
        );
        final initialPage = mode == ReaderPageMode.horizontal
            ? (tester
                          .widget<HorizontalReaderView>(
                            find.byType(HorizontalReaderView),
                          )
                          .currentSlot
                      as ReaderSlotPage)
                  .page
            : null;
        await controller.start(feedId: 'listening-reader', bookId: '1001');
        await _until(tester, () => speech.pending != null);
        for (
          var count = 0;
          controller.paragraphId != second && count < 60;
          count++
        ) {
          speech.finish();
          await _until(
            tester,
            () => controller.paragraphId == second || speech.pending != null,
          );
        }
        expect(controller.paragraphId, second);
        await tester.pumpAndSettle();
        expect(controller.status, ListeningStatus.playing);
        final saved = await service.getReadingProgress(
          feedId: 'listening-reader',
          bookId: '1001',
        );
        expect(saved!.paragraphId, second);
        expect(saved.paragraphCharOffset, 0);
        if (mode == ReaderPageMode.horizontal) {
          final page =
              (tester
                          .widget<HorizontalReaderView>(
                            find.byType(HorizontalReaderView),
                          )
                          .currentSlot
                      as ReaderSlotPage)
                  .page;
          expect(identical(page, initialPage), isFalse);
          expect(page.items.any((item) => item.paragraphId == second), isTrue);
        } else {
          final rect = tester.getRect(find.textContaining('Second paragraph.'));
          expect(rect.bottom, greaterThan(0));
          expect(
            rect.top,
            lessThan(
              tester.view.physicalSize.height / tester.view.devicePixelRatio,
            ),
          );
        }
        expect(tester.takeException(), isNull);
      } finally {
        await controller.stop();
        await tester.pumpWidget(const SizedBox());
        container.dispose();
        controller.dispose();
      }
    }
  });
}

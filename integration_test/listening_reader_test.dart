import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:langhuan/features/bookshelf/listening/listening_controller.dart';
import 'package:langhuan/features/bookshelf/listening/listening_providers.dart';
import 'package:langhuan/features/bookshelf/listening/local_speech_engine.dart';
import 'package:langhuan/features/bookshelf/reader_page.dart';
import 'package:langhuan/features/bookshelf/reading_progress_provider.dart';
import 'package:langhuan/features/bookshelf/widgets/chapter_content_manager.dart';
import 'package:langhuan/features/bookshelf/reader_settings_provider.dart';
import 'package:langhuan/features/bookshelf/widgets/horizontal_reader_view.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import 'package:langhuan/shared/app_service.dart';
import 'package:langhuan/rust_init.dart';
import 'package:langhuan/src/rust/frb_generated.dart';
import 'package:langhuan/src/rust/api/types.dart';
import 'package:langhuan/src/rust/api/transformers.dart' as transformers;

import 'fixture_feed.dart';

class _Settings extends ReaderSettingsNotifier {
  _Settings(this.mode);
  final ReaderPageMode mode;
  @override
  ReaderSettingsState build() => ReaderSettingsState(pageMode: mode);
}

class _Speech implements SpeechEngine {
  Completer<void>? pending;
  final spoken = <String>[];
  @override
  Future<List<LocalVoice>> voices() async => const [
    LocalVoice('fixture', 'Fixture', 'en-US'),
  ];
  @override
  Future<void> speak(String text, LocalVoice voice, double rate) {
    spoken.add(text);
    return (pending = Completer<void>()).future;
  }

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
            {'type': 'text', 'id': 'p3', 'content': 'Third paragraph.'},
          ]),
        );
      } else {
        request.response.write(
          request.uri.path.startsWith('/chapters/') ? '2' : '1',
        );
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
    await transformers.initializeTransformerConfiguration(
      configuration: const TransformerConfiguration(
        application: [
          TransformerConfigurationEntry(
            name: '',
            enabled: true,
            rule: TransformerRule.paragraphIndent(spaces: 2),
          ),
        ],
        books: [],
      ),
    );
    final content = await service.paragraphs(
      feedId: 'listening-reader',
      bookId: '1001',
      chapterId: '1',
    );
    final firstText = content.first as ParagraphContent_Text;
    expect(firstText.layout.firstLineIndent, 2);
    expect(firstText.content.startsWith('A long reading paragraph.'), isTrue);
    final first = firstText.id.toStringValue();
    final second = (content[1] as ParagraphContent_Text).id.toStringValue();
    final third = (content.last as ParagraphContent_Text).id.toStringValue();

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
          appDataDirectorySetProvider.overrideWith(
            (_) async => const AppDataDirectoryResult(feedCount: 1),
          ),
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
        await _until(tester, () {
          final managers = find.byType(ChapterContentManager).evaluate();
          return managers.isNotEmpty &&
              (managers.single.widget as ChapterContentManager)
                      .controller
                      .isParagraphVisible
                      ?.call('1', first) ==
                  true;
        });
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
        expect(
          speech.spoken.first.startsWith('A long reading paragraph.'),
          isTrue,
        );
        expect(speech.spoken.first.contains('　'), isFalse);
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
          final manager = tester.widget<ChapterContentManager>(
            find.byType(ChapterContentManager),
          );
          expect(manager.controller.isParagraphVisible!('1', second), isTrue);
        }
        // A real drag detaches the viewport, while narration keeps running.
        final reader = find.byType(ChapterContentManager);
        await tester.timedDrag(
          reader,
          mode == ReaderPageMode.horizontal
              ? const Offset(320, 0)
              : const Offset(0, 500),
          const Duration(milliseconds: 500),
        );
        await tester.pumpAndSettle();
        const returnKey = ValueKey('reader-return-to-listening');
        expect(find.byKey(returnKey), findsOneWidget);
        expect(controller.status, ListeningStatus.playing);
        final browsed = container.read(readingProgressProvider);
        expect(browsed.activeParagraphId, first);
        speech.finish();
        await _until(tester, () => controller.paragraphId == third);
        await tester.pumpAndSettle();
        expect(controller.status, ListeningStatus.playing);
        expect(
          container.read(readingProgressProvider).activeParagraphId,
          first,
        );
        final audioProgress = await service.getReadingProgress(
          feedId: 'listening-reader',
          bookId: '1001',
        );
        expect(audioProgress!.paragraphId, third);

        await tester.tap(find.byKey(returnKey));
        await tester.pumpAndSettle();
        expect(find.byKey(returnKey), findsNothing);
        final manager = tester.widget<ChapterContentManager>(reader);
        expect(manager.controller.isParagraphVisible!('1', third), isTrue);

        // Explicitly selecting a paragraph changes narration; browsing alone did not.
        await tester.timedDrag(
          reader,
          mode == ReaderPageMode.horizontal
              ? const Offset(320, 0)
              : const Offset(0, 500),
          const Duration(milliseconds: 500),
        );
        await tester.pumpAndSettle();
        final size = tester.getSize(reader);
        final origin = tester.getTopLeft(reader);
        await tester.longPressAt(
          origin + Offset(size.width / 2, size.height / 2),
        );
        await tester.pumpAndSettle();
        expect(find.byTooltip('Listen from here'), findsOneWidget);
        await tester.tap(find.byTooltip('Listen from here'));
        await _until(tester, () => controller.paragraphId == first);
        await tester.pumpAndSettle();
        expect(controller.status, ListeningStatus.playing);
        expect(find.byKey(returnKey), findsNothing);
        expect(
          tester.takeException(),
          isNull,
          reason: 'paragraph selection: $mode',
        );
        // Catalogue browsing and configuration changes keep the audio session
        // and its progress independent from the displayed chapter.
        await tester.tapAt(origin + Offset(size.width / 2, size.height / 2));
        await tester.pumpAndSettle();
        await tester.tap(find.text('TOC'));
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: 'opening catalogue: $mode',
        );
        await tester.tap(find.text('Chapter 2'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'catalogue jump: $mode');
        expect(container.read(readingProgressProvider).activeChapterId, '2');
        expect(controller.chapterId, '1');
        expect(controller.status, ListeningStatus.playing);
        expect(find.byKey(returnKey), findsOneWidget);
        await controller.pause();
        await controller.resume();
        await _until(
          tester,
          () => controller.status == ListeningStatus.playing,
        );
        await controller.configure(rate: 1.25);
        await tester.pumpAndSettle();
        expect(controller.chapterId, '1');
        expect(container.read(readingProgressProvider).activeChapterId, '2');
        final savedAfterNavigation = await service.getReadingProgress(
          feedId: 'listening-reader',
          bookId: '1001',
        );
        expect(savedAfterNavigation!.chapterId, '1');
        await tester.tap(find.byKey(returnKey));
        await tester.pumpAndSettle();
        expect(container.read(readingProgressProvider).activeChapterId, '1');
        expect(find.byKey(returnKey), findsNothing);
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

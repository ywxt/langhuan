import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/listening/listening_controller.dart';
import 'package:langhuan/features/bookshelf/listening/listening_panel.dart';
import 'package:langhuan/features/bookshelf/listening/local_speech_engine.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import 'package:langhuan/src/rust/api/types.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../feeds/fake_feed_service.dart';

class _Service extends FakeFeedService {
  @override
  Future<List<ChapterInfoModel>> chapters({
    required String feedId,
    required String bookId,
    bool forceRefresh = false,
  }) async => const [
    ChapterInfoModel(id: 'c1', title: '第一章 開端'),
    ChapterInfoModel(id: 'c2', title: '第二章 轉摺'),
  ];

  ParagraphContent _text(String sourceId, String content) =>
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
  }) async => [_text('p1', '第一段。'), _text('p2', '第二段。')];

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
  }) async {}
}

class _Engine implements SpeechEngine {
  final spoken = <String>[];
  Completer<void>? pending;

  @override
  Future<List<LocalVoice>> voices() async => const [
    LocalVoice('v', 'Voice', 'zh-CN'),
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
  Future<void> stop() async => finish();
}

Widget _app({required Widget home}) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: home),
);

Widget _panelOpener(ListeningController controller) => Builder(
  builder: (context) => TextButton(
    onPressed: () => showListeningPanel(context, controller, onStart: () {}),
    child: const Text('Open'),
  ),
);

/// The sheet and its fakes only use microtasks, but testWidgets runs in a
/// fake async zone where plain timers never advance — mock preferences so
/// the controller's persistence futures always complete.
void _mockPreferences() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
}

void main() {
  testWidgets('mini player shows the chapter title and progress', (
    tester,
  ) async {
    _mockPreferences();
    final controller = ListeningController(_Service(), _Engine());
    addTearDown(controller.dispose);
    await controller.start(
      feedId: 'f',
      bookId: 'b',
      chapterId: 'c1',
      bookTitle: '書名',
    );
    await tester.pumpWidget(
      _app(home: ListeningMiniPlayer(controller: controller)),
    );
    await tester.pump();
    expect(find.text('第一章 開端'), findsOneWidget);
    expect(find.text('書名 · Paragraph 1 / 2'), findsOneWidget);
    // Complete the pending utterance so the 3-minute speak timeout timer
    // cancels, and unmount the tree so the equalizer ticker disposes.
    await controller.stop();
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('rate preset chips commit the speech rate', (tester) async {
    _mockPreferences();
    final controller = ListeningController(_Service(), _Engine());
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(home: _panelOpener(controller)));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1.25×'));
    await tester.pumpAndSettle();
    expect(controller.rate, 1.25);
    await tester.tap(find.text('2×'));
    await tester.pumpAndSettle();
    expect(controller.rate, 2.0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('sleep timer chips switch modes', (tester) async {
    _mockPreferences();
    final controller = ListeningController(_Service(), _Engine());
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(home: _panelOpener(controller)));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('End of chapter'));
    await tester.pump();
    expect(controller.sleepAtChapterEnd, isTrue);
    expect(find.text('Stops after this chapter'), findsOneWidget);
    await tester.tap(find.text('15m'));
    await tester.pump();
    expect(controller.sleepAtChapterEnd, isFalse);
    expect(controller.sleepDuration, const Duration(minutes: 15));
    await tester.tap(find.text('Off'));
    await tester.pump();
    expect(controller.sleepDeadline, isNull);
    expect(controller.sleepDuration, isNull);
    expect(controller.sleepAtChapterEnd, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('setting rows carry the current value at the far end', (
    tester,
  ) async {
    _mockPreferences();
    final controller = ListeningController(_Service(), _Engine());
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(home: _panelOpener(controller)));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    // Label and value are separate widgets of one row — the app-wide
    // setting-row layout (ui-design-spec §4.5) — not a single glued
    // "Label · value" string.
    expect(find.text('Speech rate'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('listening-rate-value')))
          .data,
      '1×',
    );
    expect(find.text('Sleep timer'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('listening-sleep-value')))
          .data,
      'Off',
    );

    // Committing a preset moves the far-end summary with it.
    await tester.tap(find.text('15m'));
    await tester.pump();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('listening-sleep-value')))
          .data,
      '15m',
    );
    // Cancel the armed sleep timer before teardown.
    await controller.stop();
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('custom sleep timer dialog commits minutes', (tester) async {
    _mockPreferences();
    final controller = ListeningController(_Service(), _Engine());
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(home: _panelOpener(controller)));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('listening-custom-timer-slider')),
      const Offset(100, 0),
    );
    await tester.pump();
    await tester.tap(find.text('OK'));
    await tester.pump();
    expect(controller.sleepDuration, isNotNull);
    expect(controller.sleepDuration!.inMinutes, greaterThan(30));
    expect(controller.sleepDeadline, isNotNull);
    // Cancel the sleep timer and countdown row before teardown.
    await controller.stop();
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
  });
}

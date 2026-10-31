import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/listening/listening_controller.dart';
import 'package:langhuan/features/bookshelf/listening/listening_panel.dart';
import 'package:langhuan/features/bookshelf/listening/listening_voice_picker.dart';
import 'package:langhuan/features/bookshelf/listening/local_speech_engine.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import '../feeds/fake_feed_service.dart';

class _PreparingEngine implements SpeechEngine {
  final available = Completer<List<LocalVoice>>();
  @override
  Future<List<LocalVoice>> voices() => available.future;
  @override
  Future<void> speak(String text, LocalVoice voice, double rate) async {
    fail('Opening voice settings must not start speech');
  }

  @override
  Future<void> stop() async {}
}

void main() {
  testWidgets('voice selector is visible and usable before starting speech', (
    tester,
  ) async {
    final engine = _PreparingEngine();
    final controller = ListeningController(FakeFeedService(), engine);
    addTearDown(controller.dispose);
    var starts = 0;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showListeningPanel(
                context,
                controller,
                onStart: () => starts++,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final selector = find.byKey(const ValueKey('listening-voice-selector'));
    expect(selector, findsOneWidget);
    expect(tester.widget<ListTile>(selector).onTap, isNull);
    expect(find.text('Loading system voices…'), findsOneWidget);
    engine.available.complete(const [
      LocalVoice('zh', 'Chinese', 'zh-CN'),
      LocalVoice('zh', 'Chinese', 'zh-HK'),
    ]);
    await tester.pumpAndSettle();
    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'zh-HK'));
    await tester.pumpAndSettle();
    expect(controller.voice!.locale, 'zh-HK');
    expect(controller.status, ListeningStatus.idle);
    expect(starts, 0);
    expect(
      tester
          .widgetList<IconButton>(find.byType(IconButton))
          .singleWhere((button) => button.tooltip == 'Previous paragraph')
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widgetList<IconButton>(find.byType(IconButton))
          .singleWhere((button) => button.tooltip == 'Next paragraph')
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });
  for (final desktop in [false, true]) {
    testWidgets(
      'voice picker searches and selects by locale on ${desktop ? 'desktop' : 'phone'}',
      (tester) async {
        tester.view.physicalSize = Size(desktop ? 1100 : 400, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        const voices = [
          LocalVoice('zh', 'Chinese', 'zh-CN'),
          LocalVoice('zh', 'Chinese', 'zh-HK'),
          LocalVoice(
            'en',
            'An unusually long system voice name with additional engine details',
            'en-US',
          ),
        ];
        LocalVoice? choice;
        await tester.pumpWidget(
          MaterialApp(
            theme: desktop ? ThemeData.dark() : ThemeData.light(),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    choice = await showListeningVoicePicker(
                      context,
                      voices: voices,
                      selected: voices[1].key,
                    );
                  },
                  child: const Text('Choose voice'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Choose voice'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), desktop ? findsOneWidget : findsNothing);
        expect(find.text('zh-CN'), findsOneWidget);
        expect(find.text('zh-HK'), findsOneWidget);
        final selected = tester
            .widgetList<ListTile>(find.byType(ListTile))
            .where((tile) => tile.selected)
            .single;
        expect((selected.subtitle as Text).data, 'zh-HK');
        expect(tester.takeException(), isNull);

        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.enterText(find.byType(TextField), 'not available');
        await tester.pumpAndSettle();
        expect(find.text('No matching voices'), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'zh-CN');
        await tester.pumpAndSettle();
        expect(find.text('zh-HK'), findsNothing);
        await tester.tap(find.widgetWithText(ListTile, 'zh-CN'));
        await tester.pumpAndSettle();
        expect(choice!.key, voices[0].key);
        expect(find.byType(ListeningVoicePicker), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/listening/local_speech_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'voice names can repeat across locales without duplicate selections',
    () async {
      const channel = MethodChannel('flutter_tts');
      final selected = <Object?>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getVoices') {
              return [
                {'name': 'zh', 'locale': 'zh-CN'},
                {'name': 'zh', 'locale': 'zh-HK'},
                {'name': 'zh', 'locale': 'zh-CN'},
              ];
            }
            if (call.method == 'setVoice') selected.add(call.arguments);
            return 1;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final engine = LocalSpeechEngine(platform: TargetPlatform.android);
      final voices = await engine.voices();
      expect(voices, hasLength(2));
      expect(voices.map((voice) => voice.key).toSet(), hasLength(2));
      expect(voices.map((voice) => voice.id), everyElement('zh'));
      final hongKong = voices.singleWhere((voice) => voice.locale == 'zh-HK');
      await engine.speak('測試。', hongKong, 1);
      expect(selected, [
        {'name': 'zh', 'locale': 'zh-HK'},
      ]);
      await engine.stop();
    },
  );

  test('Apple voice selection retains the native identifier', () async {
    const channel = MethodChannel('flutter_tts');
    Object? selected;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getVoices') {
            return [
              {
                'name': 'Chinese',
                'identifier': 'native.voice.zh',
                'locale': 'zh-CN',
              },
            ];
          }
          if (call.method == 'setVoice') selected = call.arguments;
          return 1;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final engine = LocalSpeechEngine(platform: TargetPlatform.iOS);
    final voice = (await engine.voices()).single;
    await engine.speak('測試。', voice, 1);
    expect(selected, {'identifier': 'native.voice.zh'});
    await engine.stop();
  });
  test(
    'offers engine voices regardless of network or installation metadata',
    () async {
      const channel = MethodChannel('flutter_tts');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getVoices') {
              return [
                {
                  'name': 'Offline',
                  'locale': 'zh-CN',
                  'network_required': '0',
                  'features': '',
                },
                {'name': 'Cloud', 'locale': 'zh-CN', 'network_required': '1'},
                {
                  'name': 'Missing',
                  'locale': 'zh-CN',
                  'network_required': '0',
                  'features': 'notInstalled',
                },
                {'name': 'Unknown', 'locale': 'zh-CN'},
              ];
            }
            return 1;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final engine = LocalSpeechEngine(platform: TargetPlatform.android);
      final voices = await engine.voices();
      expect(voices.map((v) => v.name), [
        'Cloud',
        'Missing',
        'Offline',
        'Unknown',
      ]);
      await engine.stop();
    },
  );
}

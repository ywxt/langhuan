import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/listening/local_speech_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

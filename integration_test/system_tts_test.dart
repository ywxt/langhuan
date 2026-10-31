import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:langhuan/features/bookshelf/listening/local_speech_engine.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('installed system TTS engine synthesizes and can be reused', (
    tester,
  ) async {
    final engine = LocalSpeechEngine();
    addTearDown(engine.stop);
    final voices = await engine.voices().timeout(const Duration(seconds: 15));
    expect(
      voices,
      isNotEmpty,
      reason:
          'Install a voice in the device TTS engine before running this test.',
    );
    final voice = voices.first;
    expect(voices.map((voice) => voice.key).toSet(), hasLength(voices.length));
    // Do not filter voices by their network flags: the system owns synthesis.
    await engine.speak('語音測試。', voice, 1).timeout(const Duration(seconds: 30));
    await engine.stop();
    await engine
        .speak('測試完成。', voice, 1.2)
        .timeout(const Duration(seconds: 30));
    await engine.stop();
  });
}

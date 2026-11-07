import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../feeds/feed_providers.dart';
import '../../transformers/transformer_settings.dart';
import 'listening_audio_handler.dart';
import 'listening_controller.dart';
import 'local_speech_engine.dart';

final speechEngineProvider = Provider<SpeechEngine>(
  (ref) => LocalSpeechEngine(managedAudioSession: true),
);
final listeningBackgroundPlaybackProvider =
    Provider<ListeningBackgroundPlayback>(
      (ref) => ListeningBackgroundPlayback(),
    );
final listeningControllerProvider = Provider<ListeningController>((ref) {
  late final ListeningController controller;
  final background = ref.watch(listeningBackgroundPlaybackProvider);
  controller = ListeningController(
    ref.watch(feedServiceProvider),
    ref.watch(speechEngineProvider),
    preparePlayback: () => background.prepare(controller),
  );
  ref.listen(transformerSettingsProvider, (previous, next) {
    final before = previous?.asData?.value;
    final after = next.asData?.value;
    if (before != null &&
        after != null &&
        before.signature(controller.feedId, controller.bookId) !=
            after.signature(controller.feedId, controller.bookId)) {
      unawaited(controller.invalidateContent());
    }
  });
  ref.onDispose(background.dispose);
  ref.onDispose(controller.dispose);
  return controller;
});

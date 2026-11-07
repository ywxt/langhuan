import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

import 'listening_controller.dart';

/// Connects the existing paragraph player to the OS; it never owns a second
/// playback position or synthesizer. Desktop playback needs no mobile service.
class ListeningBackgroundPlayback {
  Future<void>? _initialization;
  Future<void> _sessionUpdate = Future.value();
  AudioSession? _session;
  ListeningAudioHandler? _handler;
  AudioHandler? get handler => _handler;
  ListeningController? _controller;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  bool _disposed = false;
  bool _wasActive = false;

  Future<void> prepare(ListeningController controller) async {
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS &&
        defaultTargetPlatform != TargetPlatform.macOS) {
      return;
    }
    // audio_service is initialized once per engine, including failed setup.
    await (_initialization ??= _initialize(controller));
    await _syncSession();
  }

  Future<void> _initialize(ListeningController controller) async {
    _handler ??= await AudioService.init(
      builder: () => ListeningAudioHandler(controller),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'org.eu.ywxt.langhuan.listening',
        androidNotificationChannelName: 'Listening',
        androidNotificationIcon: 'drawable/ic_listening',
        // A lock-screen resume must not need to start a new foreground service
        // from the background. Stop/completion releases the service normally.
        androidStopForegroundOnPause: false,
      ),
    );
    _session = await AudioSession.instance;
    await _session!.configure(const AudioSessionConfiguration.speech());
    if (_disposed) {
      _handler?.dispose();
      return;
    }
    _controller = controller;
    _wasActive = controller.active;
    controller.addListener(_onChanged);
    _subscriptions.add(
      _session!.interruptionEventStream.listen((event) {
        if (event.begin) unawaited(controller.pause());
      }),
    );
    _subscriptions.add(
      _session!.becomingNoisyEventStream.listen((_) {
        unawaited(controller.pause());
      }),
    );
  }

  Future<void> _syncSession() {
    final update = _sessionUpdate.then((_) async {
      final active = !_disposed && (_controller?.active ?? false);
      final accepted = await _session?.setActive(active) ?? true;
      if (active && !accepted) throw StateError('Audio focus was denied');
    });
    _sessionUpdate = update.catchError((Object _) {});
    return update;
  }

  void _onChanged() {
    final active = _controller!.active;
    if (_wasActive && !active) {
      unawaited(_syncSession().catchError((Object _) {}));
    }
    _wasActive = active;
  }

  void dispose() {
    _disposed = true;
    _controller?.removeListener(_onChanged);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _handler?.dispose();
    unawaited(_syncSession().catchError((Object _) {}));
  }
}

/// Notification/headset controls delegate to the same controller as the UI.
class ListeningAudioHandler extends BaseAudioHandler {
  ListeningAudioHandler(this.controller) {
    controller.addListener(_publish);
    _publish();
  }
  final ListeningController controller;

  void _publish() {
    final status = controller.status;
    if (controller.bookId.isNotEmpty) {
      mediaItem.add(
        MediaItem(
          id: '${controller.feedId}/${controller.bookId}/${controller.chapterId}',
          title: controller.chapterTitle.isNotEmpty
              ? controller.chapterTitle
              : controller.bookTitle.isNotEmpty
              ? controller.bookTitle
              : 'Langhuan',
          album: controller.bookTitle,
        ),
      );
    }
    playbackState.add(
      PlaybackState(
        controls: [
          if (controller.canMoveParagraph) MediaControl.skipToPrevious,
          controller.active ? MediaControl.pause : MediaControl.play,
          MediaControl.stop,
          if (controller.canMoveParagraph) MediaControl.skipToNext,
        ],
        processingState: switch (status) {
          // A terminal state must be idle at the OS boundary to release the
          // Android foreground service. The UI retains completed/error status.
          ListeningStatus.idle ||
          ListeningStatus.completed ||
          ListeningStatus.error => AudioProcessingState.idle,
          ListeningStatus.loading => AudioProcessingState.loading,
          _ => AudioProcessingState.ready,
        },
        playing: controller.active,
        speed: controller.rate,
        errorCode: status == ListeningStatus.error ? 1 : null,
        errorMessage: status == ListeningStatus.error
            ? '${controller.error}'
            : null,
      ),
    );
  }

  @override
  Future<void> play() => controller.resume();
  @override
  Future<void> pause() => controller.pause();
  @override
  Future<void> stop() => controller.stop();
  @override
  Future<void> skipToPrevious() => controller.moveParagraph(-1);
  @override
  Future<void> skipToNext() => controller.moveParagraph(1);
  @override
  Future<void> setSpeed(double speed) => controller.configure(rate: speed);
  @override
  Future<void> onTaskRemoved() => controller.stop();

  void dispose() {
    controller.removeListener(_publish);
    playbackState.add(
      PlaybackState(processingState: AudioProcessingState.idle),
    );
  }
}

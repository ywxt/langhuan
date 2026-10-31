import 'package:flutter/gestures.dart';

import 'reader_input_trace.dart';

/// Queues captured touch input until a display frame begins.
///
/// The caller supplies the system frame timestamp, in the same monotonic clock
/// as pointer events. Sampling never runs on packet arrival or wall-clock timers.
class FrameTouchResampler {
  FrameTouchResampler({required this.dispatch, required this.requestFrame});

  final void Function(PointerEvent) dispatch;
  final void Function() requestFrame;
  final Map<(int, int), PointerEventResampler> _devices = {};
  Duration? _lastSample;

  bool contains(PointerEvent event) =>
      _devices.containsKey((event.viewId, event.device));

  /// Completes an old sequence before the same device enters another route.
  void flushDevice(PointerEvent event) {
    _devices.remove((event.viewId, event.device))?.stop(dispatch);
    if (_devices.isEmpty) _lastSample = null;
  }

  void add(PointerEvent event) {
    if (event.kind != PointerDeviceKind.touch) {
      dispatch(event);
      return;
    }
    final key = (event.viewId, event.device);
    (_devices[key] ??= PointerEventResampler()).addEvent(event);
    requestFrame();
  }

  void sample({
    required Duration frameTime,
    required Duration interval,
    required Duration offset,
  }) {
    final sampleTime = frameTime + offset;
    if (_lastSample != null && sampleTime <= _lastSample!) {
      if (_devices.values.any((device) => device.hasPendingEvents)) {
        requestFrame();
      }
      return;
    }
    _lastSample = sampleTime;
    ReaderInputTrace.recordSampleFrame(frameTime, sampleTime, interval);
    for (final device in _devices.values.toList()) {
      device.sample(sampleTime, sampleTime + interval, dispatch);
    }
    _devices.removeWhere(
      (_, device) => !device.hasPendingEvents && !device.isDown,
    );
    if (_devices.isEmpty) _lastSample = null;
    if (_devices.values.any((device) => device.hasPendingEvents)) {
      requestFrame();
    }
  }
}

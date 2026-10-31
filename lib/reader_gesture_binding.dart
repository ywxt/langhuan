import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'shared/utils/frame_touch_resampler.dart';

/// Marks reading content for frame-synchronised touch input on Android.
/// Menus, sheets and other routes retain the normal framework input path.
class ReaderInputRegion extends SingleChildRenderObjectWidget {
  const ReaderInputRegion({super.key, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderReaderInputRegion();
}

class RenderReaderInputRegion extends RenderProxyBox {}

class ReaderGestureBinding extends WidgetsFlutterBinding
    with ReaderFrameTouchBinding {}

/// Samples each captured touch sequence once per system frame, before layout
/// and painting. No packet-arrival sampling or independently phased timer is
/// used. Capturing at pointer down keeps a gesture on one dispatch path even
/// when it leaves the reading content or a route is removed.
mixin ReaderFrameTouchBinding on WidgetsBinding {
  static const readerSamplingOffset = Duration(milliseconds: -4);
  static bool get samplingEnabledForPlatform =>
      defaultTargetPlatform == TargetPlatform.android;
  late final _frameInput = FrameTouchResampler(
    dispatch: _dispatchFrameInput,
    requestFrame: _requestInputFrame,
  );
  final Set<(int, int)> _readerContacts = {};
  int? _inputCallback;
  bool _dispatchingFrameInput = false;

  bool get dispatchingFrameInput => _dispatchingFrameInput;

  @override
  void handlePointerEvent(PointerEvent event) {
    final key = (event.viewId, event.device);
    if (samplingEnabledForPlatform &&
        event is PointerDownEvent &&
        event.kind == PointerDeviceKind.touch) {
      final result = HitTestResult();
      hitTestInView(result, event.position, event.viewId);
      if (result.path.any((entry) => entry.target is RenderReaderInputRegion)) {
        _readerContacts.add(key);
      }
      if (!_readerContacts.contains(key)) {
        _frameInput.flushDevice(event);
      }
    }
    if (_readerContacts.contains(key) || _frameInput.contains(event)) {
      _frameInput.add(event);
      if (event is PointerUpEvent ||
          event is PointerCancelEvent ||
          event is PointerRemovedEvent) {
        _readerContacts.remove(key);
      }
    } else {
      super.handlePointerEvent(event);
    }
  }

  void _dispatchFrameInput(PointerEvent event) {
    // Framework resampling stays at its default (disabled), so this does not
    // feed an already-sampled event into a second resampler.
    _dispatchingFrameInput = true;
    try {
      super.handlePointerEvent(event);
    } finally {
      _dispatchingFrameInput = false;
    }
  }

  void _requestInputFrame() {
    if (_inputCallback != null) return;
    _inputCallback = scheduleFrameCallback((_) {
      _inputCallback = null;
      final views = platformDispatcher.views;
      final refreshRate = views.isEmpty
          ? 60.0
          : views.first.display.refreshRate;
      final interval = Duration(
        microseconds: (1000000 / (refreshRate > 0 ? refreshRate : 60)).round(),
      );
      _frameInput.sample(
        frameTime: currentSystemFrameTimeStamp,
        interval: interval,
        offset: readerSamplingOffset,
      );
    });
  }
}

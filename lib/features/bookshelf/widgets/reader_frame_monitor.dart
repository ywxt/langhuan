import 'dart:developer' show Timeline;

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';

import '../../../reader_gesture_binding.dart';
import '../../../shared/utils/app_log.dart';
import '../../../shared/utils/reader_input_trace.dart';

/// Aggregates reader frame timings without producing one log line per frame.
///
/// The budget follows the display refresh rate. This matters on Linux hosts
/// with 120/144/160 Hz displays, where the familiar 16.7 ms threshold would
/// hide visible jank.
class ReaderFrameMonitor {
  ReaderFrameMonitor({required double refreshRate})
    : _refreshRate = refreshRate > 0 ? refreshRate : 60,
      _period = Stopwatch()..start();

  static const _reportInterval = Duration(seconds: 3);

  double _refreshRate;
  final Stopwatch _period;
  bool _started = false;
  int _frameCount = 0;
  int _jankyFrameCount = 0;
  int _buildOverBudgetCount = 0;
  int _rasterOverBudgetCount = 0;
  int _buildMicros = 0;
  int _rasterMicros = 0;
  int _totalMicros = 0;
  int _worstTotalMicros = 0;
  int? _touchPointer;
  int _touchSamples = 0;
  int _touchAgeMicros = 0;
  int _worstTouchAgeMicros = 0;
  String _touchSamplingMode = 'raw';
  Duration _touchSamplingOffset = Duration.zero;
  PointerDeviceKind? _inputKind;

  double get _budgetMicros => Duration.microsecondsPerSecond / _refreshRate;

  void start() {
    if (_started) return;
    _started = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    final perFrame =
        ReaderFrameTouchBinding.samplingEnabledForPlatform &&
        GestureBinding.instance is ReaderFrameTouchBinding;
    AppLog.info(
      'reader.performance',
      'frame monitor started',
      fields: {
        'refresh_hz': _refreshRate.toStringAsFixed(1),
        'budget_ms': (_budgetMicros / 1000).toStringAsFixed(2),
        'reader_touch_sampling': perFrame ? 'per_frame' : 'framework',
        if (perFrame)
          'reader_sampling_offset_ms':
              ReaderFrameTouchBinding.readerSamplingOffset.inMicroseconds /
              1000,
      },
    );
  }

  void updateRefreshRate(double refreshRate) {
    if (refreshRate <= 0) return;
    _refreshRate = refreshRate;
  }

  void stop() {
    if (!_started) return;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    _touchPointer = null;
    _flush(reason: 'reader_closed');
    _started = false;
  }

  void _onPointer(PointerEvent event) {
    if (event.kind != PointerDeviceKind.touch &&
        event.kind != PointerDeviceKind.mouse) {
      return;
    }
    ReaderInputTrace.recordEvent(event);
    if (event is PointerDownEvent) {
      _touchPointer = event.pointer;
      _inputKind = event.kind;
      _touchSamples = 0;
      _touchAgeMicros = 0;
      _worstTouchAgeMicros = 0;
      final binding = GestureBinding.instance;
      final perFrame =
          binding is ReaderFrameTouchBinding && binding.dispatchingFrameInput;
      _touchSamplingMode = perFrame
          ? 'per_frame'
          : binding.resamplingEnabled
          ? 'framework'
          : 'raw';
      _touchSamplingOffset = perFrame
          ? ReaderFrameTouchBinding.readerSamplingOffset
          : binding.resamplingEnabled
          ? binding.samplingOffset
          : Duration.zero;
    } else if (event.pointer == _touchPointer && event is PointerMoveEvent) {
      // With resampling, this timestamp is the synthetic sample time, not
      // the hardware event time. Log its age (including any lead) explicitly;
      // it must not be reported as hardware or touch-to-display latency.
      final age = Timeline.now - event.timeStamp.inMicroseconds;
      if (age.abs() > Duration.microsecondsPerSecond) return;
      _touchSamples++;
      _touchAgeMicros += age;
      if (age > _worstTouchAgeMicros) _worstTouchAgeMicros = age;
    } else if (event.pointer == _touchPointer &&
        (event is PointerUpEvent || event is PointerCancelEvent)) {
      if (_touchSamples > 0) {
        AppLog.debug(
          'reader.performance',
          'pointer event timestamp summary',
          fields: {
            'input_kind': _inputKind?.name,
            'samples': _touchSamples,
            'sampling_mode': _touchSamplingMode,
            'sampling_offset_ms': _touchSamplingOffset.inMicroseconds / 1000,
            'avg_event_age_ms': (_touchAgeMicros / _touchSamples / 1000)
                .toStringAsFixed(2),
            'worst_event_age_ms': (_worstTouchAgeMicros / 1000).toStringAsFixed(
              2,
            ),
          },
        );
      }
      _touchPointer = null;
    }
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      final build = timing.buildDuration.inMicroseconds;
      final raster = timing.rasterDuration.inMicroseconds;
      final total = timing.totalSpan.inMicroseconds;
      _frameCount++;
      _buildMicros += build;
      _rasterMicros += raster;
      _totalMicros += total;
      if (total > _worstTotalMicros) _worstTotalMicros = total;
      final buildOverBudget = build > _budgetMicros;
      final rasterOverBudget = raster > _budgetMicros;
      if (buildOverBudget) _buildOverBudgetCount++;
      if (rasterOverBudget) _rasterOverBudgetCount++;
      if (buildOverBudget || rasterOverBudget) _jankyFrameCount++;
    }
    if (_period.elapsed >= _reportInterval) _flush(reason: 'periodic');
  }

  void _flush({required String reason}) {
    if (_frameCount == 0) {
      _period.reset();
      return;
    }
    final fields = <String, Object?>{
      'reason': reason,
      'frames': _frameCount,
      'janky_frames': _jankyFrameCount,
      'janky_percent': (_jankyFrameCount * 100 / _frameCount).toStringAsFixed(
        1,
      ),
      'build_over_budget': _buildOverBudgetCount,
      'raster_over_budget': _rasterOverBudgetCount,
      'avg_build_ms': (_buildMicros / _frameCount / 1000).toStringAsFixed(2),
      'avg_raster_ms': (_rasterMicros / _frameCount / 1000).toStringAsFixed(2),
      'avg_total_ms': (_totalMicros / _frameCount / 1000).toStringAsFixed(2),
      'worst_total_ms': (_worstTotalMicros / 1000).toStringAsFixed(2),
      'budget_ms': (_budgetMicros / 1000).toStringAsFixed(2),
    };
    if (_jankyFrameCount > 0) {
      AppLog.warning(
        'reader.performance',
        'frame timing summary',
        fields: fields,
      );
    } else {
      AppLog.debug(
        'reader.performance',
        'frame timing summary',
        fields: fields,
      );
    }
    _frameCount = 0;
    _jankyFrameCount = 0;
    _buildOverBudgetCount = 0;
    _rasterOverBudgetCount = 0;
    _buildMicros = 0;
    _rasterMicros = 0;
    _totalMicros = 0;
    _worstTotalMicros = 0;
    _period.reset();
  }
}

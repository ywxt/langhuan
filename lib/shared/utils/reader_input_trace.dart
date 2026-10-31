import 'dart:developer' as developer;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

/// Opt-in profile traces correlating input delivery with page painting.
/// Coordinates remain in the local VM timeline and are not written to logs.
abstract final class ReaderInputTrace {
  static bool enabled = false;

  static void recordSampleFrame(
    Duration frameTime,
    Duration sampleTime,
    Duration interval,
  ) {
    if (!kProfileMode || !enabled) return;
    developer.Timeline.instantSync(
      'ReaderInput.sampleFrame',
      arguments: {
        'frame_time_us': frameTime.inMicroseconds,
        'sample_time_us': sampleTime.inMicroseconds,
        'interval_us': interval.inMicroseconds,
      },
    );
  }

  static void recordPacket(ui.PointerDataPacket packet) {
    if (!kProfileMode || !enabled) return;
    for (final data in packet.data) {
      if (data.kind != ui.PointerDeviceKind.touch &&
          data.kind != ui.PointerDeviceKind.mouse) {
        continue;
      }
      developer.Timeline.instantSync(
        'ReaderInput.raw',
        arguments: {
          'time_us': data.timeStamp.inMicroseconds,
          'x': data.physicalX,
          'y': data.physicalY,
          'change': data.change.name,
          'kind': data.kind.name,
          'synthesized': data.synthesized,
        },
      );
    }
  }

  static void recordEvent(PointerEvent event) {
    if (!kProfileMode || !enabled) return;
    developer.Timeline.instantSync(
      'ReaderInput.dispatched',
      arguments: {
        'time_us': event.timeStamp.inMicroseconds,
        'x': event.position.dx,
        'y': event.position.dy,
        'type': event.runtimeType.toString(),
        'kind': event.kind.name,
        'pointer': event.pointer,
      },
    );
  }

  static void recordPaint(int id, ui.Offset origin, ui.Offset painted) {
    if (!kProfileMode || !enabled) return;
    developer.Timeline.instantSync(
      'ReaderInput.paint',
      arguments: {
        'id': id,
        'x': origin.dx,
        'y': origin.dy,
        'painted_x': painted.dx,
        'painted_y': painted.dy,
      },
    );
  }
}

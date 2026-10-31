import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/shared/utils/frame_touch_resampler.dart';

void main() {
  late List<PointerEvent> events;
  late FrameTouchResampler input;
  late int requests;

  void sample(int milliseconds) => input.sample(
    frameTime: Duration(milliseconds: milliseconds),
    interval: const Duration(milliseconds: 16),
    offset: const Duration(milliseconds: -4),
  );

  PointerMoveEvent move(int milliseconds, double x, {int device = 1}) =>
      PointerMoveEvent(
        timeStamp: Duration(milliseconds: milliseconds),
        pointer: device,
        device: device,
        position: Offset(x, 0),
      );

  setUp(() {
    events = [];
    requests = 0;
    input = FrameTouchResampler(
      dispatch: events.add,
      requestFrame: () => requests++,
    );
    input.add(const PointerDownEvent(pointer: 1, device: 1));
    sample(4);
    events.clear();
  });

  test('packet arrival queues input and preserves accumulated small moves', () {
    for (var i = 1; i <= 20; i++) {
      input.add(move(i, i / 10));
    }
    expect(events, isEmpty);
    sample(20);
    final moves = events.whereType<PointerMoveEvent>().toList();
    expect(moves, hasLength(1));
    expect(moves.single.position.dx, closeTo(1.6, 1e-9));
    expect(moves.single.delta.dx, closeTo(1.6, 1e-9));
  });

  test('duplicate and backward frame times cannot dispatch more moves', () {
    input.add(move(16, 10));
    sample(20);
    input.add(move(17, 11));
    sample(20);
    sample(19);
    expect(events.whereType<PointerMoveEvent>(), hasLength(1));
    sample(24);
    final moves = events.whereType<PointerMoveEvent>().toList();
    expect(moves.last.position.dx, 11);
    expect(moves.last.timeStamp, greaterThan(moves.first.timeStamp));
  });

  test('rapid reversals retain signed movement without extrapolation', () {
    input.add(move(8, 8));
    input.add(move(12, 4));
    sample(14); // Interpolate at 10 ms, halfway through the reversal.
    expect(events.whereType<PointerMoveEvent>().last.position.dx, 6);
    input.add(move(16, 0));
    sample(24); // No newer input: hold the final position, never predict.
    final last = events.whereType<PointerMoveEvent>().last;
    expect(last.position.dx, 0);
    expect(last.delta.dx, -6);
  });

  test('flush preserves terminal events and starts a fresh clock', () {
    input.add(move(8, 5));
    input.add(
      const PointerCancelEvent(
        timeStamp: Duration(milliseconds: 9),
        pointer: 1,
        device: 1,
      ),
    );
    input.flushDevice(const PointerCancelEvent(device: 1));
    expect(events.last, isA<PointerCancelEvent>());
    events.clear();
    input.add(const PointerDownEvent(pointer: 2, device: 2));
    sample(4);
    expect(events.single, isA<PointerDownEvent>());
  });

  test('mouse wheel dispatches immediately without scheduling a frame', () {
    final before = requests;
    const mouse = PointerScrollEvent(kind: PointerDeviceKind.mouse);
    input.add(mouse);
    expect(events.single, same(mouse));
    expect(requests, before);
  });

  test(
    'independent contacts end without generating frames while stationary',
    () {
      input.add(
        const PointerDownEvent(
          pointer: 2,
          device: 2,
          timeStamp: Duration(milliseconds: 5),
        ),
      );
      sample(9);
      events.clear();
      input.add(move(8, 8));
      input.add(move(8, -8, device: 2));
      sample(12);
      final moves = events.whereType<PointerMoveEvent>().toList();
      expect(moves.map((e) => (e.pointer, e.position.dx)), [
        (1, 8.0),
        (2, -8.0),
      ]);
      events.clear();
      final before = requests;
      sample(28);
      expect(events, isEmpty);
      expect(requests, before);
      input.add(
        const PointerUpEvent(
          pointer: 1,
          device: 1,
          timeStamp: Duration(milliseconds: 30),
          position: Offset(8, 0),
        ),
      );
      input.add(
        const PointerCancelEvent(
          pointer: 2,
          device: 2,
          timeStamp: Duration(milliseconds: 30),
          position: Offset(-8, 0),
        ),
      );
      sample(40);
      expect(events.whereType<PointerUpEvent>().single.pointer, 1);
      expect(events.whereType<PointerCancelEvent>().single.pointer, 2);
    },
  );
}

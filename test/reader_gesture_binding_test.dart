import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/reader_gesture_binding.dart';

class _ReaderTestBinding extends AutomatedTestWidgetsFlutterBinding
    with ReaderFrameTouchBinding {}

void main() {
  final binding = _ReaderTestBinding();

  Widget host({VoidCallback? onReaderTap, VoidCallback? onOtherTap}) =>
      Directionality(
        textDirection: TextDirection.ltr,
        child: Row(
          children: [
            Expanded(
              child: ReaderInputRegion(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onReaderTap,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onOtherTap,
                child: const SizedBox.expand(),
              ),
            ),
          ],
        ),
      );

  testWidgets('only reading content delays touch dispatch until a frame', (
    tester,
  ) async {
    var readerTaps = 0;
    var otherTaps = 0;
    await tester.pumpWidget(
      host(onReaderTap: () => readerTaps++, onOtherTap: () => otherTaps++),
    );
    await tester.tapAt(const Offset(600, 100));
    expect(otherTaps, 1);
    await tester.tapAt(const Offset(100, 100));
    expect(readerTaps, 0);
    await tester.pump(const Duration(milliseconds: 20));
    expect(readerTaps, 1);
    expect(binding.resamplingEnabled, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
    expect(binding.transientCallbackCount, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
    'other platforms keep immediate touch dispatch inside the reader',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(host(onReaderTap: () => taps++));
      await tester.tapAt(const Offset(100, 100));
      expect(taps, 1);
      expect(binding.transientCallbackCount, 0);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'a quick tap outside completes pending reader input on the same device',
    (tester) async {
      var readerTaps = 0;
      var otherTaps = 0;
      await tester.pumpWidget(
        host(onReaderTap: () => readerTaps++, onOtherTap: () => otherTaps++),
      );
      final first = TestPointer(40, PointerDeviceKind.touch, 9);
      binding.handlePointerEvent(first.down(const Offset(100, 100)));
      binding.handlePointerEvent(first.up());
      expect(readerTaps, 0);
      final second = TestPointer(41, PointerDeviceKind.touch, 9);
      binding.handlePointerEvent(second.down(const Offset(600, 100)));
      binding.handlePointerEvent(second.up());
      expect(readerTaps, 1);
      expect(otherTaps, 1);
      await tester.pump(const Duration(milliseconds: 20));
      expect(binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('mouse clicks keep immediate dispatch inside the reader', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(host(onReaderTap: () => taps++));
    await tester.tapAt(const Offset(100, 100), kind: PointerDeviceKind.mouse);
    expect(taps, 1);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('Linux mouse input keeps immediate dispatch in reading content', (
    tester,
  ) async {
    var readerTaps = 0;
    var otherTaps = 0;
    await tester.pumpWidget(
      host(onReaderTap: () => readerTaps++, onOtherTap: () => otherTaps++),
    );
    await tester.tapAt(const Offset(600, 100), kind: PointerDeviceKind.mouse);
    expect(otherTaps, 1);
    await tester.tapAt(const Offset(100, 100), kind: PointerDeviceKind.mouse);
    expect(readerTaps, 1);
    expect(binding.transientCallbackCount, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('cancellation survives removal of the reading route', (
    tester,
  ) async {
    final events = <PointerEvent>[];
    binding.pointerRouter.addGlobalRoute(events.add);
    addTearDown(() => binding.pointerRouter.removeGlobalRoute(events.add));
    await tester.pumpWidget(host());
    final finger = await tester.startGesture(
      const Offset(100, 100),
      pointer: 31,
    );
    await tester.pump(const Duration(milliseconds: 20));
    expect(events.whereType<PointerDownEvent>(), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await finger.cancel(timeStamp: const Duration(milliseconds: 25));
    await tester.pump(const Duration(milliseconds: 40));
    expect(events.whereType<PointerCancelEvent>(), hasLength(1));
    expect(binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}

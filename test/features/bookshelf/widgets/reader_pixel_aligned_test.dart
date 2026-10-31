import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/widgets/reader_pixel_aligned.dart';

class _PaintCounter extends CustomPainter {
  int paints = 0;

  @override
  void paint(Canvas canvas, Size size) {
    paints++;
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
  }

  @override
  bool shouldRepaint(_PaintCounter oldDelegate) => false;
}

void main() {
  testWidgets(
    'paint stays pixel aligned while retaining the cached paragraph',
    (tester) async {
      tester.view.devicePixelRatio = 3.5;
      addTearDown(tester.view.resetDevicePixelRatio);
      final offset = ValueNotifier(0.0);
      addTearDown(offset.dispose);
      final painter = _PaintCounter();
      const paragraphKey = ValueKey('paragraph');

      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: ValueListenableBuilder<double>(
              valueListenable: offset,
              child: ReaderPixelAligned(
                child: RepaintBoundary(
                  child: CustomPaint(
                    key: paragraphKey,
                    painter: painter,
                    size: const Size(80, 80),
                  ),
                ),
              ),
              builder: (context, value, child) => Transform.translate(
                offset: Offset(0.13, value),
                child: child,
              ),
            ),
          ),
        ),
      );
      final initialPaints = painter.paints;
      expect(initialPaints, greaterThan(0));

      // Cross pixel boundaries in both directions, with a stationary interval.
      for (final value in [0.07, 0.19, 0.31, 0.31, 0.19, -0.07, -0.31]) {
        offset.value = value;
        await tester.pump();
        final origin = tester.getTopLeft(find.byKey(paragraphKey)) * 3.5;
        expect(origin.dx, closeTo(origin.dx.roundToDouble(), 1e-6));
        expect(origin.dy, closeTo(origin.dy.roundToDouble(), 1e-6));
        expect(painter.paints, initialPaints);
      }
    },
  );
}

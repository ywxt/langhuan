import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/widgets/reader_page_canvas_painter.dart';

class _CanvasContext extends PaintingContext {
  _CanvasContext(this.canvas)
    : super(ContainerLayer(), const Rect.fromLTWH(0, 0, 32, 32));

  @override
  final Canvas canvas;
}

void main() {
  testWidgets('fractional page translations preserve one-pixel strokes', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final painter = ReaderPageCanvasPainter();
      final sourceRecorder = ui.PictureRecorder();
      final sourceCanvas = Canvas(sourceRecorder);
      sourceCanvas.drawColor(const Color(0xffffffff), BlendMode.src);
      for (final x in [2.0, 5.0, 8.0]) {
        sourceCanvas.drawRect(
          Rect.fromLTWH(x, 1, 1, 10),
          Paint()
            ..color = const Color(0xff000000)
            ..isAntiAlias = false,
        );
      }
      final sourcePicture = sourceRecorder.endRecording();
      final image = await sourcePicture.toImage(12, 12);
      sourcePicture.dispose();
      const ratio = 3.5;

      for (final physicalOffset in [0.1, 0.35, 0.6, 1.2, 2.8]) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)
          ..drawColor(const Color(0xffffffff), BlendMode.src)
          ..scale(ratio)
          ..translate(physicalOffset / ratio, 0);
        painter.paintSnapshot(
          _CanvasContext(canvas),
          Offset.zero,
          const Size(12 / ratio, 12 / ratio),
          image,
          const Size(12, 12),
          ratio,
        );
        final picture = recorder.endRecording();
        final rendered = await picture.toImage(32, 32);
        picture.dispose();
        final data = (await rendered.toByteData())!;
        var blackPixels = 0;
        for (var i = 0; i < data.lengthInBytes; i += 4) {
          final value = data.getUint8(i);
          expect(value, anyOf(0, 255), reason: 'strokes must not be blurred');
          if (value == 0) blackPixels++;
        }
        expect(blackPixels, 30, reason: 'all three strokes retain their width');
        rendered.dispose();
      }
      image.dispose();
      painter.dispose();
    });
  });
}

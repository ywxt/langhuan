import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Paints a retained reading page as an unfiltered, one-to-one pixel copy.
///
/// Pages are already rasterized at the display's pixel ratio. Resizing their
/// source rectangles or applying mipmap filtering is unnecessary for a pure
/// translation and can make fine strokes change as the page moves.
class ReaderPageCanvasPainter extends SnapshotPainter {
  @override
  void paintSnapshot(
    PaintingContext context,
    Offset offset,
    Size size,
    ui.Image image,
    Size sourceSize,
    double pixelRatio,
  ) {
    final canvas = context.canvas;
    canvas.save();
    canvas.clipRect(offset & size);
    canvas.translate(offset.dx, offset.dy);
    canvas.scale(1 / pixelRatio);
    canvas.drawImage(
      image,
      Offset.zero,
      Paint()
        ..isAntiAlias = false
        ..filterQuality = FilterQuality.none,
    );
    canvas.restore();
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset,
    Size size,
    PaintingContextCallback painter,
  ) => painter(context, offset);

  @override
  bool shouldRepaint(ReaderPageCanvasPainter oldPainter) => false;
}

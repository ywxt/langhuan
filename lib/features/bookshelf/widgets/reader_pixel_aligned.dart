import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../../shared/utils/reader_input_trace.dart';

/// Aligns a cached paragraph or page's paint origin without rounding its
/// scrolling or animation state.
///
/// This must sit outside its child's repaint boundary. Otherwise scrolling
/// translates the retained layer without repainting this object, bypassing the
/// alignment. Layout and accumulated subpixel finger movements remain intact.
class ReaderPixelAligned extends SingleChildRenderObjectWidget {
  const ReaderPixelAligned({super.key, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderReaderPixelAligned(MediaQuery.devicePixelRatioOf(context));

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderReaderPixelAligned renderObject,
  ) {
    renderObject.devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
  }
}

class RenderReaderPixelAligned extends RenderProxyBox {
  RenderReaderPixelAligned(this._devicePixelRatio);

  double _devicePixelRatio;
  Offset _paintTranslation = Offset.zero;

  set devicePixelRatio(double value) {
    if (value == _devicePixelRatio) return;
    _devicePixelRatio = value;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    final origin = localToGlobal(Offset.zero);
    _paintTranslation = Offset(
      (origin.dx * _devicePixelRatio).roundToDouble() / _devicePixelRatio -
          origin.dx,
      (origin.dy * _devicePixelRatio).roundToDouble() / _devicePixelRatio -
          origin.dy,
    );
    ReaderInputTrace.recordPaint(hashCode, origin, origin + _paintTranslation);
    context.paintChild(child, offset + _paintTranslation);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      result.addWithPaintOffset(
        offset: _paintTranslation,
        position: position,
        hitTest: (result, position) =>
            super.hitTestChildren(result, position: position),
      );

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    super.applyPaintTransform(child, transform);
    transform.translateByDouble(
      _paintTranslation.dx,
      _paintTranslation.dy,
      0,
      1,
    );
  }
}

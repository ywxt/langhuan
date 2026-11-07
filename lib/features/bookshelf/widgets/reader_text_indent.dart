import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// A layout-only first-line spacer. Its placeholder is never part of source
/// text, paragraph identities, saved character offsets, or speech input.
class ReaderTextIndent {
  static double width(
    double em,
    TextStyle style,
    TextScaler scaler,
    double maxWidth, {
    double? minimumContentWidth,
  }) {
    if (em <= 0) return 0;
    final font = style.fontSize ?? 14;
    final scale = font > 0 ? scaler.scale(font) / font : 1.0;
    // Always leave room for a glyph, including on narrow/large-text screens.
    final available = maxWidth.isFinite
        ? maxWidth / scale - (minimumContentWidth ?? font)
        : em * font;
    return math.min(em * font, math.max(0, available));
  }

  static TextSpan span(TextSpan text, double width) => width <= 0
      ? text
      : TextSpan(
          style: text.style,
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.bottom,
              child: ExcludeSemantics(child: SizedBox(width: width, height: 0)),
            ),
            text,
          ],
        );

  static PlaceholderDimensions dimensions(double width, double scale) =>
      PlaceholderDimensions(
        size: Size(width * scale, 0),
        alignment: PlaceholderAlignment.bottom,
      );
}

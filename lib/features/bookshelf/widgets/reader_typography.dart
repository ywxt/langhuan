import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart' show TextTheme, TextStyle;

/// The reading surface's text-style recipe.
///
/// Pagination ([PageBreaker]), glyph warmup, and both rendering views
/// (vertical [ParagraphView], horizontal [PageContentView]) must lay out
/// chapter text with identical styles, or page breaks and pre-rasterized
/// glyphs drift from what is actually painted. The recipe therefore lives
/// in this one type instead of hand-copied `copyWith` chains.
class ReaderTypography {
  const ReaderTypography({
    required this.textTheme,
    this.fontScale = 1.0,
    this.fontFamily,
    this.letterSpacing = 0.0,
    this.lineHeight = 1.8,
  });

  /// Theme the reader styles are derived from.
  final TextTheme textTheme;

  /// Multiplier applied to the theme's base sizes.
  final double fontScale;

  /// User-selected reading font; null keeps the theme's family.
  final String? fontFamily;

  final double letterSpacing;

  /// Line-height multiplier for body paragraphs.
  final double lineHeight;

  /// Alternate half-width CJK punctuation (標點擠壓, OpenType `halt`).
  /// Fonts without the feature ignore it, so it stays always-on rather
  /// than growing a setting.
  static const List<FontFeature> _punctuationSqueeze = [FontFeature('halt')];

  /// Chapter title style: scaled [TextTheme.headlineSmall] with no height
  /// override, matching the historic hand-copied recipes.
  TextStyle get title => (textTheme.headlineSmall ?? const TextStyle())
      .copyWith(
        fontSize: (textTheme.headlineSmall?.fontSize ?? 24) * fontScale,
        fontFamily: fontFamily,
        letterSpacing: letterSpacing,
        fontFeatures: _punctuationSqueeze,
      );

  /// Body paragraph style: scaled [TextTheme.bodyLarge] at [lineHeight].
  TextStyle get body => (textTheme.bodyLarge ?? const TextStyle()).copyWith(
        fontSize: (textTheme.bodyLarge?.fontSize ?? 16) * fontScale,
        fontFamily: fontFamily,
        letterSpacing: letterSpacing,
        height: lineHeight,
        fontFeatures: _punctuationSqueeze,
      );
}

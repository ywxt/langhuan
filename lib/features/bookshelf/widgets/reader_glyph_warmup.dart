import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../src/rust/api/types.dart';

/// Pre-rasterizes glyphs from nearby chapters while no animation is active.
///
/// User-loaded CJK fonts can spend tens of milliseconds growing Impeller's
/// glyph atlas when a paragraph first enters the viewport. Layout alone does
/// not populate that atlas, so this paints the chapter's unique glyphs into a
/// small off-screen image at idle priority. The image is discarded; the
/// renderer's glyph atlas remains warm for the real paragraph paint.
class ReaderGlyphWarmup {
  // Keep each off-screen atlas update below one 60 Hz frame on mid-range
  // Android GPUs. Half comes from each chapter edge so both scroll directions
  // have their first visible line ready.
  static const _maxGlyphsPerStyle = 16;
  static const _maxRememberedChapters = 24;

  final Set<String> _scheduled = <String>{};
  final List<String> _scheduleOrder = <String>[];

  void schedule({
    required String chapterId,
    required List<ParagraphContent> paragraphs,
    required TextStyle bodyStyle,
    required TextStyle titleStyle,
    required double width,
    required double devicePixelRatio,
    required TextDirection textDirection,
  }) {
    final family = bodyStyle.fontFamily;
    if (family == null ||
        family.isEmpty ||
        width <= 0 ||
        devicePixelRatio <= 0) {
      return;
    }

    final cacheKey = [
      chapterId,
      family,
      bodyStyle.fontSize,
      titleStyle.fontSize,
      bodyStyle.fontWeight,
      devicePixelRatio,
    ].join(':');
    if (!_scheduled.add(cacheKey)) return;
    _scheduleOrder.add(cacheKey);
    while (_scheduleOrder.length > _maxRememberedChapters) {
      _scheduled.remove(_scheduleOrder.removeAt(0));
    }

    final bodyGlyphs = <int>{};
    final titleGlyphs = <int>{};
    for (final paragraph in paragraphs) {
      final (text, target) = switch (paragraph) {
        ParagraphContent_Title(:final text) => (text, titleGlyphs),
        ParagraphContent_Text(:final content) => (content, bodyGlyphs),
        ParagraphContent_Image() => ('', bodyGlyphs),
      };
      for (final rune in text.runes) {
        if (!_isWhitespace(rune)) target.add(rune);
      }
    }

    unawaited(
      SchedulerBinding.instance.scheduleTask<void>(
        () async {
          try {
            await _warmBoundaries(
              bodyGlyphs,
              style: bodyStyle,
              width: width,
              devicePixelRatio: devicePixelRatio,
              textDirection: textDirection,
            );
            await _warmBoundaries(
              titleGlyphs,
              style: titleStyle,
              width: width,
              devicePixelRatio: devicePixelRatio,
              textDirection: textDirection,
            );
          } catch (_) {
            // Warming is an optional optimization; font/rendering failures
            // must never stop the reader from showing the real text.
          }
        },
        Priority.idle,
        debugLabel: 'reader glyph warmup',
      ),
    );
  }

  static bool _isWhitespace(int rune) =>
      rune == 0x20 || (rune >= 0x09 && rune <= 0x0d) || rune == 0x3000;

  static Future<void> _warmBoundaries(
    Set<int> glyphs, {
    required TextStyle style,
    required double width,
    required double devicePixelRatio,
    required TextDirection textDirection,
  }) async {
    if (glyphs.isEmpty) return;
    final all = glyphs.toList(growable: false);
    final selected = all.length <= _maxGlyphsPerStyle
        ? all
        : <int>{
            ...all.take(_maxGlyphsPerStyle ~/ 2),
            ...all.reversed.take(_maxGlyphsPerStyle ~/ 2),
          }.toList(growable: false);
    final painter = TextPainter(
      text: TextSpan(text: String.fromCharCodes(selected), style: style),
      textDirection: textDirection,
    )..layout(maxWidth: width);

    final imageWidth = (painter.width * devicePixelRatio).ceil().clamp(
      1,
      (width * devicePixelRatio).ceil(),
    );
    final imageHeight = (painter.height * devicePixelRatio).ceil().clamp(
      1,
      4096,
    );
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)..scale(devicePixelRatio);
    painter.paint(canvas, Offset.zero);
    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(imageWidth, imageHeight);
      image.dispose();
    } finally {
      picture.dispose();
      painter.dispose();
    }
  }
}

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';

/// The paragraph-comment badge: a compact 💬 + count capsule that flows
/// inline right after a paragraph's last character (see [BadgedText]).
///
/// Only paragraphs whose source reports a non-zero comment count carry a
/// badge — see the reader's paragraph-comment plumbing for the "last
/// fragment per source paragraph" dedup that keeps split paragraphs from
/// stacking badges.
class CommentBadge extends StatelessWidget {
  const CommentBadge({super.key, required this.count, this.onTap});

  final int count;

  /// Invoked when the user taps the badge. The badge is the only tap
  /// target for comments — the surrounding paragraph stays free for the
  /// reader's tap-to-toggle-controls gesture.
  final VoidCallback? onTap;

  static const inlineGap = 6.0;
  static const _horizontalPadding = 7.0;
  static const _verticalPadding = 3.0;
  static const _iconSize = 12.0;
  static const _labelGap = 3.0;

  /// Unscaled placeholder dimensions. WidgetSpan applies the paragraph's
  /// text scaler once; the badge's inner text must not scale a second time.
  ///
  /// Geometry depends only on (count, direction, locale, label style), so
  /// sizes are cached process-wide: pagination and every badge render re-use
  /// one measurement per distinct count instead of re-shaping the label.
  static Size inlineSize(BuildContext context, int count) {
    final style = DefaultTextStyle.of(context).style.merge(
      Theme.of(context).textTheme.labelSmall?.copyWith(height: 1.1),
    );
    final direction = Directionality.of(context);
    final locale = Localizations.localeOf(context);
    final key = (count, direction, locale, style);
    final cached = _inlineSizeCache[key];
    if (cached != null) return cached;
    final painter = TextPainter(
      text: TextSpan(text: formatCommentCount(count, context), style: style),
      textDirection: direction,
      locale: locale,
    )..layout();
    final size = Size(
      inlineGap +
          _horizontalPadding * 2 +
          _iconSize +
          _labelGap +
          painter.width,
      _verticalPadding * 2 +
          (painter.height > _iconSize ? painter.height : _iconSize),
    );
    painter.dispose();
    if (_inlineSizeCache.length >= _inlineSizeCacheLimit) {
      _inlineSizeCache.clear();
    }
    _inlineSizeCache[key] = size;
    return size;
  }

  /// Badge labels repeat heavily across chapters and renders; a full clear
  /// on overflow keeps the cache bounded without bookkeeping.
  static const _inlineSizeCacheLimit = 512;
  static final _inlineSizeCache =
      <(int, TextDirection, Locale, TextStyle), Size>{};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final badge = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: _horizontalPadding,
        vertical: _verticalPadding,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: _iconSize,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: _labelGap),
          Text(
            formatCommentCount(count, context),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return badge;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: badge,
    );
  }
}

/// Paragraph text with the comment badge flowing inline right after the
/// last character — the official-app placement. A null or non-positive
/// [commentCount] renders a plain [Text].
class BadgedText extends StatelessWidget {
  /// Keep the last complete text grapheme, closing punctuation and spaces
  /// with the badge, so punctuation cannot become an isolated final line.
  /// Source strings and persisted UTF-16 offsets are never modified.
  static String tailText(String text) {
    final graphemes = text.characters.toList();
    var start = graphemes.length;
    while (start > 0) {
      start--;
      if (!_trailingPunctuation.hasMatch(graphemes[start])) break;
    }
    return graphemes.skip(start).join();
  }

  static final _trailingPunctuation = RegExp(r'^[\s\p{P}]+$', unicode: true);

  static TextSpan inlineSpan(String text, TextStyle? style, Widget tail) =>
      TextSpan(
        text: text.substring(0, text.length - tailText(text).length),
        style: style,
        children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: tail,
          ),
        ],
      );

  static PlaceholderDimensions tailDimensions(
    String text,
    TextStyle style,
    Size badgeSize,
    TextDirection direction,
    Locale? locale, {
    double scale = 1,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: tailText(text), style: style),
      textDirection: direction,
      locale: locale,
    )..layout();
    final size = Size(
      painter.width + badgeSize.width,
      painter.height > badgeSize.height ? painter.height : badgeSize.height,
    );
    final baseline =
        painter.computeDistanceToActualBaseline(TextBaseline.alphabetic) +
        (size.height - painter.height) / 2;
    painter.dispose();
    return PlaceholderDimensions(
      size: size * scale,
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      baselineOffset: baseline * scale,
    );
  }

  const BadgedText({
    super.key,
    required this.text,
    required this.style,
    this.textAlign,
    this.commentCount,
    this.onCommentTap,
    this.badgeGap,
  });

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;

  /// Source-reported paragraph-comment total; drives the trailing badge.
  final int? commentCount;

  /// Opens the comments when the trailing badge is tapped.
  final VoidCallback? onCommentTap;

  /// Supplied by pagination so every fragment uses the same paragraph layout.
  final double? badgeGap;

  @override
  Widget build(BuildContext context) {
    final count = commentCount;
    if (count == null || count <= 0) {
      return Text(text, style: style, textAlign: textAlign);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final effectiveStyle = DefaultTextStyle.of(context).style.merge(style);
        final layout = badgeGap == null
            ? CommentParagraphLayout.resolve(
                text: text,
                style: effectiveStyle,
                badgeSize: CommentBadge.inlineSize(context, count),
                width: constraints.maxWidth,
                textScaler: MediaQuery.textScalerOf(context),
                direction: Directionality.of(context),
                locale: Localizations.localeOf(context),
                align: textAlign ?? TextAlign.start,
              )
            : CommentParagraphLayout(effectiveStyle, badgeGap!);
        return Text.rich(
          inlineSpan(
            text,
            layout.style,
            MediaQuery.withNoTextScaling(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(tailText(text), style: layout.style),
                  // The capsule's smaller label must not supply the Row's baseline.
                  IgnoreBaseline(
                    child: SizedBox.fromSize(
                      size: layout.badgeSize(
                        CommentBadge.inlineSize(context, count),
                      ),
                      child: Padding(
                        padding: EdgeInsets.only(left: layout.gap),
                        child: CommentBadge(count: count, onTap: onCommentTap),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          textAlign: textAlign,
        );
      },
    );
  }
}

/// Paragraph-wide tracking, bounded to 0.05 em. Glyphs are never scaled.
/// Compression is applied only if it avoids the extra line caused by a badge.
class CommentParagraphLayout {
  const CommentParagraphLayout(this.style, this.gap);

  final TextStyle style;
  final double gap;

  Size badgeSize(Size original) =>
      Size(original.width - CommentBadge.inlineGap + gap, original.height);

  static CommentParagraphLayout resolve({
    required String text,
    required TextStyle style,
    required Size badgeSize,
    required double width,
    required TextScaler textScaler,
    required TextDirection direction,
    required Locale? locale,
    required TextAlign align,
  }) {
    final original = CommentParagraphLayout(style, CommentBadge.inlineGap);
    if (!width.isFinite || width <= 0 || text.isEmpty) return original;
    final fontSize = style.fontSize ?? 14;
    final scale = fontSize == 0 ? 0.0 : textScaler.scale(fontSize) / fontSize;

    TextPainter badged(CommentParagraphLayout layout) {
      final painter = TextPainter(
        text: BadgedText.inlineSpan(
          text,
          layout.style,
          const SizedBox.shrink(),
        ),
        textDirection: direction,
        textAlign: align,
        textScaler: textScaler,
        locale: locale,
      );
      painter.setPlaceholderDimensions([
        BadgedText.tailDimensions(
          text,
          layout.style,
          layout.badgeSize(badgeSize),
          direction,
          locale,
          scale: scale,
        ),
      ]);
      painter.layout(maxWidth: width);
      return painter;
    }

    int lineCount(TextPainter painter) {
      final count = painter.computeLineMetrics().length;
      painter.dispose();
      return count;
    }

    final plain = TextPainter(
      text: TextSpan(text: text, style: original.style),
      textDirection: direction,
      textAlign: align,
      textScaler: textScaler,
      locale: locale,
    )..layout(maxWidth: width);
    final plainLines = plain.computeLineMetrics();
    plain.dispose();
    final target = plainLines.length;
    if (target == 0) return original;
    final leftover = width - plainLines.last.width;

    if (lineCount(badged(original)) <= target) return original;

    // The badge wraps to an extra line. Reclaim exactly the overflowing
    // width instead of searching for it: the previous binary searches
    // re-shaped the whole paragraph up to 17 extra times, which dominated
    // pagination cost for badge-dense chapters.
    const minGap = 2.0;

    // Stage 1 — a smaller badge gap alone can free enough room.
    final gapCandidate = leftover - badgeSize.width + CommentBadge.inlineGap;
    if (gapCandidate >= minGap) {
      final tightened = CommentParagraphLayout(
        style,
        (gapCandidate - 0.25).clamp(minGap, CommentBadge.inlineGap),
      );
      if (lineCount(badged(tightened)) <= target) return tightened;
    }

    // Stage 2 — letter-spacing reduction, gap already minimal.
    final overflow =
        badgeSize.width - CommentBadge.inlineGap + minGap - leftover;
    final tracking = style.letterSpacing ?? 0;
    final maxReduction = fontSize * 0.05;
    CommentParagraphLayout reduced(double amount) => CommentParagraphLayout(
      style.copyWith(letterSpacing: tracking - amount),
      minGap,
    );
    bool fitsReduction(double amount) {
      if (amount > maxReduction) return false;
      return lineCount(badged(reduced(amount))) <= target;
    }

    final glyphCount = text.characters.length;
    var reduction = overflow / (glyphCount > 0 ? glyphCount : 1) * 1.2 + 0.05;
    if (reduction > maxReduction) reduction = maxReduction;
    if (fitsReduction(reduction)) {
      // Prefer the loosest tracking that fits: one halving probe recovers
      // most of the slack the safety margin added.
      final relaxed = reduction / 2;
      if (relaxed >= 0.05 && fitsReduction(relaxed)) {
        return reduced(relaxed);
      }
      return reduced(reduction);
    }
    // Line-break discreteness can overshoot the linear estimate; correct
    // once before giving up (the badge then takes its own line, as before).
    final corrected = (reduction * 1.6).clamp(reduction, maxReduction);
    if (corrected > reduction && fitsReduction(corrected)) {
      return reduced(corrected);
    }
    return original;
  }
}

/// Badge count display: raw below the locale's compression threshold, one
/// decimal place above it (zh compresses at 10000 → 1.2萬; others at 1000 →
/// 11.6K).
String formatCommentCount(int count, BuildContext context) {
  if (count <= 0) return '0';
  final threshold = Localizations.localeOf(context).languageCode == 'zh'
      ? 10000
      : 1000;
  if (count < threshold) return '$count';
  final value = (count / threshold)
      .toStringAsFixed(1)
      .replaceAll(RegExp(r'\.0$'), '');
  return AppLocalizations.of(context).readerCommentCountCompact(value);
}

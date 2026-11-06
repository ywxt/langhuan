import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/loading.dart';
import '../../../src/rust/api/types.dart';
import 'comment_badge.dart';

/// Renders a single [ParagraphContent] item (title, text, or image).
class ParagraphView extends StatelessWidget {
  const ParagraphView({
    super.key,
    required this.paragraph,
    this.fontScale = 1.0,
    this.fontFamily,
    this.letterSpacing = 0.0,
    this.paragraphSpacing = LanghuanTheme.spaceMd,
    this.lineHeight = 1.8,
    this.selected = false,
    this.onLongPress,
    this.commentCount,
    this.onCommentTap,
  });

  final ParagraphContent paragraph;
  final double fontScale;
  final String? fontFamily;
  final double letterSpacing;
  final double paragraphSpacing;
  final double lineHeight;
  final bool selected;
  final void Function(Rect globalRect)? onLongPress;

  /// Source-reported paragraph-comment total. A positive value shows the
  /// badge; the whole paragraph block becomes tappable via [onCommentTap].
  final int? commentCount;

  /// Opens this paragraph's comments. Only set when a badge shows; wired
  /// to the badge itself so paragraph taps keep the reader-wide
  /// tap-to-toggle-controls behaviour.
  final VoidCallback? onCommentTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showBadge = commentCount != null && commentCount! > 0;

    final child = switch (paragraph) {
      ParagraphContent_Title(:final text) => BadgedText(
        text: text,
        style: theme.textTheme.headlineSmall?.copyWith(
          fontSize: (theme.textTheme.headlineSmall?.fontSize ?? 24) * fontScale,
          fontFamily: fontFamily,
          letterSpacing: letterSpacing,
        ),
        textAlign: TextAlign.center,
        commentCount: commentCount,
        onCommentTap: onCommentTap,
      ),
      ParagraphContent_Text(:final content) => BadgedText(
        text: content,
        style: theme.textTheme.bodyLarge?.copyWith(
          fontSize: (theme.textTheme.bodyLarge?.fontSize ?? 16) * fontScale,
          fontFamily: fontFamily,
          letterSpacing: letterSpacing,
          height: lineHeight,
        ),
        commentCount: commentCount,
        onCommentTap: onCommentTap,
      ),
      ParagraphContent_Image(:final url, :final alt) => Builder(
        builder: (context) {
          final screenWidth = MediaQuery.sizeOf(context).width;
          final dpr = MediaQuery.devicePixelRatioOf(context);
          final cacheWidth = (screenWidth * dpr).round();
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ClipRRect(
                borderRadius: LanghuanTheme.borderRadiusMd,
                child: Image.network(
                  url,
                  fit: BoxFit.cover,
                  cacheWidth: cacheWidth,
                  loadingBuilder: (context, child, progress) {
                    if (progress == null) return child;
                    return const AspectRatio(
                      aspectRatio: 16 / 9,
                      child: Center(child: LanghuanSpinner()),
                    );
                  },
                  errorBuilder: (_, _, _) => const AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Center(child: Icon(Icons.broken_image_outlined)),
                  ),
                ),
              ),
              if (alt != null && alt.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(
                    top: paragraphSpacing.clamp(4.0, 32.0),
                  ),
                  child: Text(
                    alt,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              if (showBadge)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(top: LanghuanTheme.spaceSm),
                    child: CommentBadge(
                      count: commentCount!,
                      onTap: onCommentTap,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    };

    Widget result = child;

    if (selected) {
      result = DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
        ),
        child: result,
      );
    }

    if (onLongPress != null) {
      return GestureDetector(
        onLongPress: () => _reportLongPress(context, onLongPress!),
        onSecondaryTapUp: (_) => _reportLongPress(context, onLongPress!),
        child: result,
      );
    }
    return result;
  }

  void _reportLongPress(
    BuildContext context,
    void Function(Rect globalRect) report,
  ) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final topLeft = box.localToGlobal(Offset.zero);
    report(topLeft & box.size);
  }
}

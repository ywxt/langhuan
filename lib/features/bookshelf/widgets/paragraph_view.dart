import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../src/rust/api/types.dart';

/// Renders a single [ParagraphContent] item (title, text, or image).
class ParagraphView extends StatelessWidget {
  const ParagraphView({
    super.key,
    required this.paragraph,
    this.fontScale = 1.0,
    this.lineHeight = 1.8,
    this.onLongPress,
  });

  final ParagraphContent paragraph;
  final double fontScale;
  final double lineHeight;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final child = switch (paragraph) {
      ParagraphContent_Title(:final text) => Text(
          text,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontSize:
                (theme.textTheme.headlineSmall?.fontSize ?? 24) * fontScale,
          ),
          textAlign: TextAlign.center,
        ),
      ParagraphContent_Text(:final content) => Text(
          content,
          style: theme.textTheme.bodyLarge?.copyWith(
            fontSize:
                (theme.textTheme.bodyLarge?.fontSize ?? 16) * fontScale,
            height: lineHeight,
          ),
        ),
      ParagraphContent_Image(:final url, :final alt) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: LanghuanTheme.borderRadiusMd,
              child: Image.network(
                url,
                fit: BoxFit.cover,
                loadingBuilder: (context, child, progress) {
                  if (progress == null) return child;
                  return const AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Center(child: CircularProgressIndicator()),
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
                padding: const EdgeInsets.only(top: LanghuanTheme.spaceSm),
                child: Text(
                  alt,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
    };

    if (onLongPress != null) {
      return GestureDetector(
        onLongPress: onLongPress,
        child: child,
      );
    }
    return child;
  }
}

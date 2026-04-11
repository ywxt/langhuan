import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../src/rust/api/types.dart';

/// Renders a single [ParagraphContent] item (title, text, or image).
///
/// Used by both the vertical-scroll reader (inside a [ListView]) and the
/// horizontal-paging reader (inside a [PageView]).  Callers are responsible
/// for adding any surrounding padding or scroll view.
class ParagraphView extends StatelessWidget {
  const ParagraphView({super.key, required this.item});

  final ParagraphContent item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (item is ParagraphContent_Title) {
      return Text(
        (item as ParagraphContent_Title).text,
        style: theme.textTheme.headlineSmall,
        textAlign: TextAlign.center,
      );
    }

    if (item is ParagraphContent_Text) {
      return Text(
        (item as ParagraphContent_Text).content,
        style: theme.textTheme.bodyLarge?.copyWith(height: 1.8),
      );
    }

    if (item is ParagraphContent_Image) {
      final img = item as ParagraphContent_Image;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: LanghuanTheme.borderRadiusMd,
            child: Image.network(
              img.url,
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
          if (img.alt != null && img.alt!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: LanghuanTheme.spaceSm),
              child: Text(
                img.alt!,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ),
        ],
      );
    }

    return const SizedBox.shrink();
  }
}

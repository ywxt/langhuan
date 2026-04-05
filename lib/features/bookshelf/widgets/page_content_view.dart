import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../src/bindings/signals/signals.dart';
import 'page_breaker.dart';

/// Renders a single computed [PageContent] — a list of [PageItem]s that
/// together fill one page of the horizontal-paging reader.
///
/// Titles and images are rendered identically to [ParagraphView].
/// Text paragraphs respect the optional [PageItem.startOffset] /
/// [PageItem.endOffset] to display only the visible portion.
class PageContentView extends StatelessWidget {
  const PageContentView({super.key, required this.page});

  final PageContent page;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = page.items;

    // ClipRect absorbs sub-pixel overflow from page-breaking rounding.
    return ClipRect(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (int i = 0; i < items.length; i++) ...[
            if (i > 0)
              SizedBox(
                height: items[i].source is ParagraphContentImage
                    ? LanghuanTheme.spaceLg
                    : LanghuanTheme.spaceMd,
              ),
            _buildItem(context, theme, items[i]),
          ],
        ],
      ),
    );
  }

  Widget _buildItem(BuildContext context, ThemeData theme, PageItem item) {
    final source = item.source;

    if (source is ParagraphContentTitle) {
      return Text(
        source.text,
        style: theme.textTheme.headlineSmall,
        textAlign: TextAlign.center,
      );
    }

    if (source is ParagraphContentText) {
      final text = item.isPartial ? item.visibleText : source.content;
      return Text(
        text,
        style: theme.textTheme.bodyLarge?.copyWith(height: 1.8),
      );
    }

    if (source is ParagraphContentImage) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: LanghuanTheme.borderRadiusMd,
            child: Image.network(
              source.url,
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
          if (source.alt != null && source.alt!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: LanghuanTheme.spaceSm),
              child: Text(
                source.alt!,
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

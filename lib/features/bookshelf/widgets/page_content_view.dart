import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/loading.dart';
import '../../../src/rust/api/types.dart';
import 'page_breaker.dart';

/// Renders a single computed [PageContent] — a list of [PageItem]s that
/// together fill one page of the horizontal-paging reader.
class PageContentView extends StatelessWidget {
  const PageContentView({
    super.key,
    required this.page,
    this.fontScale = 1.0,
    this.fontFamily,
    this.letterSpacing = 0.0,
    this.paragraphSpacing = LanghuanTheme.spaceMd,
    this.lineHeight = 1.8,
    this.selectedParagraphId,
    this.onParagraphLongPress,
  });

  final PageContent page;
  final double fontScale;
  final String? fontFamily;
  final double letterSpacing;
  final double paragraphSpacing;
  final double lineHeight;
  final String? selectedParagraphId;
  final void Function(
    String paragraphId,
    ParagraphContent paragraph,
    Rect globalRect,
  )?
  onParagraphLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = page.items;

    return ClipRect(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (int i = 0; i < items.length; i++) ...[
            if (i > 0) SizedBox(height: paragraphSpacing),
            _buildItem(context, theme, items[i]),
          ],
        ],
      ),
    );
  }

  Widget _buildItem(BuildContext context, ThemeData theme, PageItem item) {
    final source = item.source;
    final isSelected = selectedParagraphId == item.paragraphId;
    Widget child = _buildContent(context, theme, item, source);

    if (isSelected) {
      child = DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
        ),
        child: child,
      );
    }

    if (onParagraphLongPress != null) {
      // Scope the context to this item: the view's own context resolves to
      // the whole-page render object, which would place the selection
      // overlay at the page top instead of next to the pressed paragraph.
      return Builder(
        builder: (itemContext) => GestureDetector(
          onLongPress: () {
            final box = itemContext.findRenderObject() as RenderBox?;
            if (box == null || !box.hasSize) return;
            final topLeft = box.localToGlobal(Offset.zero);
            onParagraphLongPress!(item.paragraphId, source, topLeft & box.size);
          },
          child: child,
        ),
      );
    }
    return child;
  }

  Widget _buildContent(
    BuildContext context,
    ThemeData theme,
    PageItem item,
    ParagraphContent source,
  ) {
    if (source is ParagraphContent_Title) {
      return Text(
        source.text,
        style: theme.textTheme.headlineSmall?.copyWith(
          fontSize: (theme.textTheme.headlineSmall?.fontSize ?? 24) * fontScale,
          fontFamily: fontFamily,
          letterSpacing: letterSpacing,
        ),
        textAlign: TextAlign.center,
      );
    }

    if (source is ParagraphContent_Text) {
      final text = item.isPartial ? item.visibleText : source.content;
      return Text(
        text,
        style: theme.textTheme.bodyLarge?.copyWith(
          fontSize: (theme.textTheme.bodyLarge?.fontSize ?? 16) * fontScale,
          fontFamily: fontFamily,
          letterSpacing: letterSpacing,
          height: lineHeight,
        ),
      );
    }

    if (source is ParagraphContent_Image) {
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
              source.url,
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

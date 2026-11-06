import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/loading.dart';
import '../../../src/rust/api/types.dart';
import 'comment_badge.dart';
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
    this.commentBadgeIds = const {},
    this.onParagraphComments,
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

  /// Identity strings of paragraphs that carry a comment badge (last
  /// fragment per source paragraph — see the content manager). Empty when
  /// comment badges are disabled.
  final Set<String> commentBadgeIds;

  /// Opens a paragraph's comments. Only invoked for items that show a badge.
  final void Function(String chapterId, ParagraphContent paragraph)?
  onParagraphComments;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = page.items;

    return ClipRect(
      // While a typography change re-paginates, the manager keeps the
      // previous page displayed (see ChapterContentManager): its measured
      // boundaries render at the new sizes and can exceed the page height.
      // A non-scrollable viewport lets that overflow clip silently instead
      // of tripping the Flex overflow assertion; pages fresh out of
      // pagination always fit their measured layout, so nothing changes
      // for them.
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (int i = 0; i < items.length; i++) ...[
              // The gap plus the page's distributed leftover: pages that
              // broke at a text boundary stretch their gaps to fill the
              // page ([PageContent.extraGap]); other pages pass a zero
              // leftover.
              if (i > 0) SizedBox(height: paragraphSpacing + page.extraGap),
              _buildItem(context, theme, items[i]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildItem(BuildContext context, ThemeData theme, PageItem item) {
    final source = item.source;
    final isSelected = selectedParagraphId == item.paragraphId;

    // The badge follows the final fragment of the source paragraph.
    final count = source.commentCount;
    final badgeCount =
        item.endOffset == null &&
            count != null &&
            count > 0 &&
            commentBadgeIds.contains(item.paragraphId)
        ? count
        : null;
    final badgeTap = badgeCount != null && onParagraphComments != null
        ? () => onParagraphComments!(page.chapterId, source)
        : null;
    Widget child = _buildContent(
      context,
      theme,
      item,
      source,
      badgeCount,
      badgeTap,
    );

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
        builder: (itemContext) {
          void selectParagraph() {
            final box = itemContext.findRenderObject() as RenderBox?;
            if (box == null || !box.hasSize) return;
            final topLeft = box.localToGlobal(Offset.zero);
            onParagraphLongPress!(item.paragraphId, source, topLeft & box.size);
          }

          return GestureDetector(
            onLongPress: selectParagraph,
            onSecondaryTapUp: (_) => selectParagraph(),
            child: child,
          );
        },
      );
    }
    return child;
  }

  Widget _buildContent(
    BuildContext context,
    ThemeData theme,
    PageItem item,
    ParagraphContent source,
    int? badgeCount,
    VoidCallback? badgeTap,
  ) {
    if (source is ParagraphContent_Title) {
      return BadgedText(
        text: item.isPartial ? item.visibleText : source.text,
        style: theme.textTheme.headlineSmall?.copyWith(
          fontSize: (theme.textTheme.headlineSmall?.fontSize ?? 24) * fontScale,
          fontFamily: fontFamily,
          letterSpacing: item.letterSpacing ?? letterSpacing,
        ),
        textAlign: TextAlign.center,
        commentCount: badgeCount,
        badgeGap: item.badgeGap,
        badgeCompact: item.badgeCompact,
        onCommentTap: badgeTap,
      );
    }

    if (source is ParagraphContent_Text) {
      return BadgedText(
        text: item.isPartial ? item.visibleText : source.content,
        style: theme.textTheme.bodyLarge?.copyWith(
          fontSize: (theme.textTheme.bodyLarge?.fontSize ?? 16) * fontScale,
          fontFamily: fontFamily,
          letterSpacing: item.letterSpacing ?? letterSpacing,
          height: lineHeight,
        ),
        commentCount: badgeCount,
        badgeGap: item.badgeGap,
        badgeCompact: item.badgeCompact,
        onCommentTap: badgeTap,
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
          if (badgeCount != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: LanghuanTheme.spaceSm),
                child: CommentBadge(count: badgeCount, onTap: badgeTap),
              ),
            ),
        ],
      );
    }

    return const SizedBox.shrink();
  }
}

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../src/rust/api/types.dart';
import '../../feeds/feed_service.dart' show ParagraphIdStringExt;

// ─────────────────────────────────────────────────────────────────────────────
// Data models
// ─────────────────────────────────────────────────────────────────────────────

class PageItem {
  const PageItem({
    required this.source,
    required this.paragraphIndex,
    required this.paragraphId,
    this.startOffset,
    this.endOffset,
  });

  final ParagraphContent source;
  final int paragraphIndex;
  final String paragraphId;
  final int? startOffset;
  final int? endOffset;

  String get visibleText {
    if (source is! ParagraphContent_Text) return '';
    final full = (source as ParagraphContent_Text).content;
    final s = startOffset ?? 0;
    final e = endOffset ?? full.length;
    return full.substring(s, e);
  }

  bool get isPartial => startOffset != null || endOffset != null;
}

class PageContent {
  const PageContent({required this.items, this.chapterId = ''});

  final List<PageItem> items;

  /// Chapter this page belongs to (set by the content manager when pages
  /// from several chapters are concatenated into one list).
  final String chapterId;

  int get firstParagraphIndex => items.isEmpty ? 0 : items.first.paragraphIndex;
  String get firstParagraphId => items.isEmpty ? '' : items.first.paragraphId;

  /// Character offset of the page-leading character within its paragraph
  /// (0 when the page starts at a paragraph boundary).
  int get firstCharOffset {
    final item = items.isEmpty ? null : items.first;
    if (item == null) return 0;
    if (item.source is ParagraphContent_Text) return item.startOffset ?? 0;
    return 0;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Page breaker
// ─────────────────────────────────────────────────────────────────────────────

class PageBreaker {
  PageBreaker({
    required this.pageSize,
    required this.textStyle,
    required this.titleStyle,
    required this.paragraphSpacing,
    required this.imageHeight,
    required this.textDirection,
  });

  final Size pageSize;
  final TextStyle textStyle;
  final TextStyle titleStyle;
  final double paragraphSpacing;
  final double imageHeight;
  final ui.TextDirection textDirection;

  List<PageContent> computePages(
    List<ParagraphContent> items, {
    String chapterId = '',
  }) {
    if (items.isEmpty) return const [];

    final double w = pageSize.width;
    final double h = pageSize.height - 4.0;

    if (w <= 0 || h <= 0) {
      return [
        PageContent(
          chapterId: chapterId,
          items: [
            for (int i = 0; i < items.length; i++)
              PageItem(
                source: items[i],
                paragraphIndex: i,
                paragraphId: items[i].id.toStringValue(),
              ),
          ],
        ),
      ];
    }

    final List<PageContent> pages = [];
    List<PageItem> cur = [];
    double remaining = h;

    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      final spacing = cur.isEmpty ? 0.0 : paragraphSpacing;

      if (item is ParagraphContent_Title) {
        final th = _measureTitle(item.text, w);
        if (remaining - spacing < th && cur.isNotEmpty) {
          pages.add(PageContent(chapterId: chapterId, items: cur));
          cur = [];
          remaining = h;
        }
        final sp = cur.isEmpty ? 0.0 : paragraphSpacing;
        remaining -= sp + th;
        cur.add(
          PageItem(
            source: item,
            paragraphIndex: i,
            paragraphId: item.id.toStringValue(),
          ),
        );
      } else if (item is ParagraphContent_Image) {
        if (remaining - spacing < imageHeight && cur.isNotEmpty) {
          pages.add(PageContent(chapterId: chapterId, items: cur));
          cur = [];
          remaining = h;
        }
        final sp = cur.isEmpty ? 0.0 : paragraphSpacing;
        remaining -= sp + imageHeight;
        cur.add(
          PageItem(
            source: item,
            paragraphIndex: i,
            paragraphId: item.id.toStringValue(),
          ),
        );
      } else if (item is ParagraphContent_Text) {
        _layoutText(
          chapterId: chapterId,
          text: item.content,
          paragraphIndex: i,
          paragraphId: item.id.toStringValue(),
          source: item,
          width: w,
          pageHeight: h,
          remaining: remaining,
          currentItems: cur,
          pages: pages,
          onUpdate: (newItems, newRemaining) {
            cur = newItems;
            remaining = newRemaining;
          },
        );
      }
    }

    if (cur.isNotEmpty) {
      pages.add(PageContent(chapterId: chapterId, items: cur));
    }

    return pages.isEmpty
        ? [
            PageContent(
              chapterId: chapterId,
              items: [
                for (int i = 0; i < items.length; i++)
                  PageItem(
                    source: items[i],
                    paragraphIndex: i,
                    paragraphId: items[i].id.toStringValue(),
                  ),
              ],
            ),
          ]
        : pages;
  }

  double _measureTitle(String text, double maxWidth) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: titleStyle),
      textDirection: textDirection,
      maxLines: null,
    )..layout(maxWidth: maxWidth);
    final result = tp.height;
    tp.dispose();
    return result;
  }

  void _layoutText({
    required String chapterId,
    required String text,
    required int paragraphIndex,
    required String paragraphId,
    required ParagraphContent_Text source,
    required double width,
    required double pageHeight,
    required double remaining,
    required List<PageItem> currentItems,
    required List<PageContent> pages,
    required void Function(List<PageItem>, double) onUpdate,
  }) {
    // Shape the paragraph once and split pages from its line metrics.
    // Re-shaping the remaining substring after every split made pagination
    // quadratic in paragraph length — several times slower with ordinary
    // reading fonts, pathological with user-loaded ones, whose missing
    // glyphs pay a per-glyph fallback lookup on every layout.
    //
    // Splits therefore follow the paragraph's own line grid. The old
    // substring version re-wrapped whatever followed a split as a fresh
    // paragraph, so a split landing before a line's hung trailing spaces
    // shifted every later line boundary and under-filled the remaining
    // pages; keeping the grid fills pages to their true capacity.
    final tp = TextPainter(
      text: TextSpan(text: text, style: textStyle),
      textDirection: textDirection,
      maxLines: null,
    )..layout(maxWidth: width);

    final lineMetrics = tp.computeLineMetrics();
    // Suffix sums of line heights: "does the rest of the paragraph fit?"
    // in O(1).
    final suffixHeights = List<double>.filled(lineMetrics.length + 1, 0);
    for (var i = lineMetrics.length - 1; i >= 0; i--) {
      suffixHeights[i] = suffixHeights[i + 1] + lineMetrics[i].height;
    }

    double spacingFor(List<PageItem> items) =>
        items.isEmpty ? 0.0 : paragraphSpacing;

    var charStart = 0;
    var lineIdx = 0;
    var remainingSpace = remaining;

    while (charStart < text.length) {
      if (lineIdx >= lineMetrics.length) {
        // Degenerate tail: characters that lay out to no lines (e.g. a
        // whitespace run past the last line). Keep them as an item on the
        // current page, like the substring-layout version did.
        currentItems.add(
          PageItem(
            source: source,
            paragraphIndex: paragraphIndex,
            paragraphId: paragraphId,
            startOffset: charStart == 0 ? null : charStart,
          ),
        );
        pages.add(PageContent(chapterId: chapterId, items: currentItems));
        currentItems = [];
        remainingSpace = pageHeight;
        tp.dispose();
        onUpdate(currentItems, remainingSpace);
        return;
      }

      final sp = spacingFor(currentItems);
      final space = remainingSpace - sp;

      // Everything left fits on the current page.
      if (space >= suffixHeights[lineIdx]) {
        tp.dispose();
        remainingSpace -= sp + suffixHeights[lineIdx];
        currentItems.add(
          PageItem(
            source: source,
            paragraphIndex: paragraphIndex,
            paragraphId: paragraphId,
            startOffset: charStart == 0 ? null : charStart,
          ),
        );
        onUpdate(currentItems, remainingSpace);
        return;
      }

      if (space <= 0 ||
          (space < lineMetrics[lineIdx].height && currentItems.isNotEmpty)) {
        pages.add(PageContent(chapterId: chapterId, items: currentItems));
        currentItems = [];
        remainingSpace = pageHeight;
        continue;
      }

      var accH = 0.0;
      var fitLines = 0;
      for (var i = lineIdx; i < lineMetrics.length; i++) {
        if (accH + lineMetrics[i].height > space + 0.5) break;
        accH += lineMetrics[i].height;
        fitLines++;
      }

      if (fitLines == 0) {
        if (currentItems.isNotEmpty) {
          pages.add(PageContent(chapterId: chapterId, items: currentItems));
          currentItems = [];
          remainingSpace = pageHeight;
          continue;
        }
        fitLines = 1;
      }

      final lastLine = lineMetrics[lineIdx + fitLines - 1];
      final bottom = lastLine.baseline + lastLine.descent;
      final position = tp.getPositionForOffset(Offset(width, bottom - 1));
      var splitChar = position.offset;
      if (splitChar <= charStart) splitChar = charStart + 1;
      if (splitChar > text.length) splitChar = text.length;

      currentItems.add(
        PageItem(
          source: source,
          paragraphIndex: paragraphIndex,
          paragraphId: paragraphId,
          startOffset: charStart == 0 ? null : charStart,
          endOffset: splitChar,
        ),
      );

      pages.add(PageContent(chapterId: chapterId, items: currentItems));
      currentItems = [];
      remainingSpace = pageHeight;
      charStart = splitChar;
      lineIdx += fitLines;
    }

    tp.dispose();
    onUpdate(currentItems, remainingSpace);
  }

  static int pageForParagraph(List<PageContent> pages, String paragraphId) {
    for (int i = 0; i < pages.length; i++) {
      for (final item in pages[i].items) {
        if (item.paragraphId == paragraphId) return i;
      }
    }
    return (pages.length - 1).clamp(0, pages.length);
  }

  /// Finds the page a saved position should restore to.
  ///
  /// A paragraph can span pages, so the paragraph id alone cannot tell its
  /// start page from its continuation page. [charOffset] is the character
  /// offset of the page-leading character within the paragraph that was
  /// reported when the position was saved. Matching goes:
  ///
  /// 1. exact: the page whose first item is (`paragraphId`, `charOffset`) —
  ///    the very page the reader left (same layout);
  /// 2. near: the first page whose first item is `paragraphId` with any
  ///    offset — closest guess after a re-flow shifted the offsets;
  /// 3. fallback: the first page containing `paragraphId` anywhere.
  static int pageForPosition(
    List<PageContent> pages,
    String paragraphId,
    int charOffset,
  ) {
    for (int i = 0; i < pages.length; i++) {
      if (pages[i].firstParagraphId == paragraphId &&
          pages[i].firstCharOffset == charOffset) {
        return i;
      }
    }
    for (int i = 0; i < pages.length; i++) {
      if (pages[i].firstParagraphId == paragraphId) return i;
    }
    return pageForParagraph(pages, paragraphId);
  }
}

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../src/bindings/signals/signals.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Data models
// ─────────────────────────────────────────────────────────────────────────────

/// A single item within a computed page.
///
/// Wraps a [ParagraphContent] and optionally restricts visible text to a
/// sub-range (for text paragraphs that were split across pages).
class PageItem {
  const PageItem({
    required this.source,
    required this.paragraphIndex,
    this.startOffset,
    this.endOffset,
  });

  /// The original paragraph content.
  final ParagraphContent source;

  /// Index of this paragraph in the full content list.
  final int paragraphIndex;

  /// For [ParagraphContentText] only: character offset of the visible
  /// sub-string start.  `null` means start from the beginning.
  final int? startOffset;

  /// For [ParagraphContentText] only: character offset of the visible
  /// sub-string end (exclusive).  `null` means display to the end.
  final int? endOffset;

  /// Returns the visible text for a [ParagraphContentText] item,
  /// respecting [startOffset] / [endOffset].
  String get visibleText {
    if (source is! ParagraphContentText) return '';
    final full = (source as ParagraphContentText).content;
    final s = startOffset ?? 0;
    final e = endOffset ?? full.length;
    return full.substring(s, e);
  }

  /// `true` when this item shows a partial (split) text paragraph.
  bool get isPartial => startOffset != null || endOffset != null;
}

/// One computed page of content — a list of [PageItem]s that fit together
/// within the available page height.
class PageContent {
  const PageContent({required this.items});

  final List<PageItem> items;

  /// The paragraph index of the first item on this page.
  int get firstParagraphIndex => items.isEmpty ? 0 : items.first.paragraphIndex;
}

// ─────────────────────────────────────────────────────────────────────────────
// Page breaker
// ─────────────────────────────────────────────────────────────────────────────

/// Splits a list of [ParagraphContent] into pages that fit within
/// [pageSize], using [TextPainter] to measure rendered heights.
///
/// Long text paragraphs are split at line boundaries so that every page is
/// filled as much as possible.  Titles and images are treated as atomic
/// blocks — if they don't fit on the current page they are pushed to the
/// next one.
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

  /// Computes the list of pages from [items].
  List<PageContent> computePages(List<ParagraphContent> items) {
    if (items.isEmpty) return const [];

    final double availableWidth = pageSize.width;
    final double availableHeight = pageSize.height;

    if (availableWidth <= 0 || availableHeight <= 0) {
      // Degenerate size — put everything on one page.
      return [
        PageContent(
          items: [
            for (int i = 0; i < items.length; i++)
              PageItem(source: items[i], paragraphIndex: i),
          ],
        ),
      ];
    }

    final List<PageContent> pages = [];
    List<PageItem> currentPageItems = [];
    double remainingHeight = availableHeight;

    for (int i = 0; i < items.length; i++) {
      final item = items[i];

      // Add spacing before this item (except the first item on the page).
      final spacing = currentPageItems.isEmpty ? 0.0 : paragraphSpacing;

      if (item is ParagraphContentTitle) {
        final h = _measureTitle(item.text, availableWidth);
        if (remainingHeight - spacing < h && currentPageItems.isNotEmpty) {
          // Doesn't fit → flush current page, start new one.
          pages.add(PageContent(items: currentPageItems));
          currentPageItems = [];
          remainingHeight = availableHeight;
        }
        final actualSpacing = currentPageItems.isEmpty ? 0.0 : paragraphSpacing;
        remainingHeight -= actualSpacing + h;
        currentPageItems.add(PageItem(source: item, paragraphIndex: i));
      } else if (item is ParagraphContentImage) {
        final h = imageHeight;
        if (remainingHeight - spacing < h && currentPageItems.isNotEmpty) {
          pages.add(PageContent(items: currentPageItems));
          currentPageItems = [];
          remainingHeight = availableHeight;
        }
        final actualSpacing = currentPageItems.isEmpty ? 0.0 : paragraphSpacing;
        remainingHeight -= actualSpacing + h;
        currentPageItems.add(PageItem(source: item, paragraphIndex: i));
      } else if (item is ParagraphContentText) {
        _layoutTextParagraph(
          text: item.content,
          paragraphIndex: i,
          source: item,
          availableWidth: availableWidth,
          availableHeight: availableHeight,
          spacing: spacing,
          remainingHeight: remainingHeight,
          currentPageItems: currentPageItems,
          pages: pages,
          onUpdateState: (newItems, newRemaining) {
            currentPageItems = newItems;
            remainingHeight = newRemaining;
          },
        );
      }
    }

    // Flush last page.
    if (currentPageItems.isNotEmpty) {
      pages.add(PageContent(items: currentPageItems));
    }

    return pages.isEmpty
        ? [
            PageContent(
              items: [
                for (int i = 0; i < items.length; i++)
                  PageItem(source: items[i], paragraphIndex: i),
              ],
            ),
          ]
        : pages;
  }

  // ─── Private helpers ───────────────────────────────────────────────────

  double _measureTitle(String text, double maxWidth) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: titleStyle),
      textDirection: textDirection,
      maxLines: null,
    )..layout(maxWidth: maxWidth);
    final h = tp.height;
    tp.dispose();
    return h;
  }

  /// Lays out a text paragraph, splitting it across pages if necessary.
  void _layoutTextParagraph({
    required String text,
    required int paragraphIndex,
    required ParagraphContentText source,
    required double availableWidth,
    required double availableHeight,
    required double spacing,
    required double remainingHeight,
    required List<PageItem> currentPageItems,
    required List<PageContent> pages,
    required void Function(List<PageItem>, double) onUpdateState,
  }) {
    int charStart = 0;

    while (charStart < text.length) {
      final substring = text.substring(charStart);

      final tp = TextPainter(
        text: TextSpan(text: substring, style: textStyle),
        textDirection: textDirection,
        maxLines: null,
      )..layout(maxWidth: availableWidth);

      final fullHeight = tp.height;
      final actualSpacing = currentPageItems.isEmpty ? 0.0 : paragraphSpacing;
      final spaceForText = remainingHeight - actualSpacing;

      if (spaceForText >= fullHeight) {
        // Entire remaining text fits on this page.
        tp.dispose();
        remainingHeight -= actualSpacing + fullHeight;
        currentPageItems.add(
          PageItem(
            source: source,
            paragraphIndex: paragraphIndex,
            startOffset: charStart == 0 ? null : charStart,
            endOffset: null,
          ),
        );
        onUpdateState(currentPageItems, remainingHeight);
        return;
      }

      if (spaceForText <= 0 ||
          (spaceForText < tp.preferredLineHeight &&
              currentPageItems.isNotEmpty)) {
        // No room at all — flush page, try again with a fresh page.
        tp.dispose();
        pages.add(PageContent(items: currentPageItems));
        currentPageItems = [];
        remainingHeight = availableHeight;
        continue;
      }

      // Partial fit — find how many lines fit.
      final lineMetrics = tp.computeLineMetrics();
      double accumulatedHeight = 0;
      int fitLines = 0;
      for (final line in lineMetrics) {
        if (accumulatedHeight + line.height > spaceForText + 0.5) break;
        accumulatedHeight += line.height;
        fitLines++;
      }

      if (fitLines == 0) {
        // Not even one line fits — flush and retry.
        tp.dispose();
        if (currentPageItems.isNotEmpty) {
          pages.add(PageContent(items: currentPageItems));
          currentPageItems = [];
          remainingHeight = availableHeight;
          continue;
        }
        // Edge case: a single line is taller than the entire page.
        // Force it onto this page to avoid infinite loop.
        fitLines = 1;
        if (lineMetrics.isEmpty) {
          currentPageItems.add(
            PageItem(
              source: source,
              paragraphIndex: paragraphIndex,
              startOffset: charStart == 0 ? null : charStart,
              endOffset: null,
            ),
          );
          tp.dispose();
          pages.add(PageContent(items: currentPageItems));
          currentPageItems = [];
          remainingHeight = availableHeight;
          onUpdateState(currentPageItems, remainingHeight);
          return;
        }
      }

      // Find character offset at the end of the last fitting line.
      final lastFitLine = lineMetrics[fitLines - 1];
      final bottomOfLastLine = lastFitLine.baseline + lastFitLine.descent;
      final position = tp.getPositionForOffset(
        Offset(availableWidth, bottomOfLastLine - 1),
      );
      int splitChar = charStart + position.offset;

      // Ensure we make progress.
      if (splitChar <= charStart) {
        splitChar = charStart + 1;
      }
      // Clamp to text length.
      if (splitChar > text.length) {
        splitChar = text.length;
      }

      tp.dispose();

      // Add partial item to current page.
      currentPageItems.add(
        PageItem(
          source: source,
          paragraphIndex: paragraphIndex,
          startOffset: charStart == 0 ? null : charStart,
          endOffset: splitChar,
        ),
      );

      // Flush page.
      pages.add(PageContent(items: currentPageItems));
      currentPageItems = [];
      remainingHeight = availableHeight;
      charStart = splitChar;
    }

    onUpdateState(currentPageItems, remainingHeight);
  }

  /// Finds the page index that contains [paragraphIndex].
  static int pageForParagraph(List<PageContent> pages, int paragraphIndex) {
    for (int i = 0; i < pages.length; i++) {
      for (final item in pages[i].items) {
        if (item.paragraphIndex == paragraphIndex) return i;
      }
    }
    return (pages.length - 1).clamp(0, pages.length);
  }
}

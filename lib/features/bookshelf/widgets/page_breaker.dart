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
  const PageContent({required this.items});

  final List<PageItem> items;

  int get firstParagraphIndex => items.isEmpty ? 0 : items.first.paragraphIndex;
  String get firstParagraphId => items.isEmpty ? '' : items.first.paragraphId;
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

  List<PageContent> computePages(List<ParagraphContent> items) {
    if (items.isEmpty) return const [];

    final double w = pageSize.width;
    final double h = pageSize.height - 4.0;

    if (w <= 0 || h <= 0) {
      return [
        PageContent(
          items: [
            for (int i = 0; i < items.length; i++)
              PageItem(source: items[i], paragraphIndex: i, paragraphId: items[i].id.toStringValue()),
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
          pages.add(PageContent(items: cur));
          cur = [];
          remaining = h;
        }
        final sp = cur.isEmpty ? 0.0 : paragraphSpacing;
        remaining -= sp + th;
        cur.add(PageItem(source: item, paragraphIndex: i, paragraphId: item.id.toStringValue()));
      } else if (item is ParagraphContent_Image) {
        if (remaining - spacing < imageHeight && cur.isNotEmpty) {
          pages.add(PageContent(items: cur));
          cur = [];
          remaining = h;
        }
        final sp = cur.isEmpty ? 0.0 : paragraphSpacing;
        remaining -= sp + imageHeight;
        cur.add(PageItem(source: item, paragraphIndex: i, paragraphId: item.id.toStringValue()));
      } else if (item is ParagraphContent_Text) {
        _layoutText(
          text: item.content,
          paragraphIndex: i,
          paragraphId: item.id.toStringValue(),
          source: item,
          width: w,
          pageHeight: h,
          spacing: spacing,
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
      pages.add(PageContent(items: cur));
    }

    return pages.isEmpty
        ? [
            PageContent(
              items: [
                for (int i = 0; i < items.length; i++)
                  PageItem(source: items[i], paragraphIndex: i, paragraphId: items[i].id.toStringValue()),
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
    required String text,
    required int paragraphIndex,
    required String paragraphId,
    required ParagraphContent_Text source,
    required double width,
    required double pageHeight,
    required double spacing,
    required double remaining,
    required List<PageItem> currentItems,
    required List<PageContent> pages,
    required void Function(List<PageItem>, double) onUpdate,
  }) {
    int charStart = 0;

    while (charStart < text.length) {
      final substring = text.substring(charStart);
      final tp = TextPainter(
        text: TextSpan(text: substring, style: textStyle),
        textDirection: textDirection,
        maxLines: null,
      )..layout(maxWidth: width);

      final fullH = tp.height;
      final sp = currentItems.isEmpty ? 0.0 : paragraphSpacing;
      final space = remaining - sp;

      if (space >= fullH) {
        tp.dispose();
        remaining -= sp + fullH;
        currentItems.add(PageItem(
          source: source,
          paragraphIndex: paragraphIndex,
          paragraphId: paragraphId,
          startOffset: charStart == 0 ? null : charStart,
        ));
        onUpdate(currentItems, remaining);
        return;
      }

      if (space <= 0 ||
          (space < tp.preferredLineHeight && currentItems.isNotEmpty)) {
        tp.dispose();
        pages.add(PageContent(items: currentItems));
        currentItems = [];
        remaining = pageHeight;
        continue;
      }

      final lineMetrics = tp.computeLineMetrics();
      double accH = 0;
      int fitLines = 0;
      for (final line in lineMetrics) {
        if (accH + line.height > space + 0.5) break;
        accH += line.height;
        fitLines++;
      }

      if (fitLines == 0) {
        tp.dispose();
        if (currentItems.isNotEmpty) {
          pages.add(PageContent(items: currentItems));
          currentItems = [];
          remaining = pageHeight;
          continue;
        }
        fitLines = 1;
        if (lineMetrics.isEmpty) {
          currentItems.add(PageItem(
            source: source,
            paragraphIndex: paragraphIndex,
            paragraphId: paragraphId,
            startOffset: charStart == 0 ? null : charStart,
          ));
          tp.dispose();
          pages.add(PageContent(items: currentItems));
          currentItems = [];
          remaining = pageHeight;
          onUpdate(currentItems, remaining);
          return;
        }
      }

      final lastLine = lineMetrics[fitLines - 1];
      final bottom = lastLine.baseline + lastLine.descent;
      final position =
          tp.getPositionForOffset(Offset(width, bottom - 1));
      int splitChar = charStart + position.offset;
      if (splitChar <= charStart) splitChar = charStart + 1;
      if (splitChar > text.length) splitChar = text.length;

      tp.dispose();

      currentItems.add(PageItem(
        source: source,
        paragraphIndex: paragraphIndex,
        paragraphId: paragraphId,
        startOffset: charStart == 0 ? null : charStart,
        endOffset: splitChar,
      ));

      pages.add(PageContent(items: currentItems));
      currentItems = [];
      remaining = pageHeight;
      charStart = splitChar;
    }

    onUpdate(currentItems, remaining);
  }

  static int pageForParagraph(List<PageContent> pages, String paragraphId) {
    for (int i = 0; i < pages.length; i++) {
      for (final item in pages[i].items) {
        if (item.paragraphId == paragraphId) return i;
      }
    }
    return (pages.length - 1).clamp(0, pages.length);
  }
}

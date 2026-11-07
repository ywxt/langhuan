import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../src/rust/api/types.dart';
import '../../feeds/feed_service.dart' show ParagraphIdStringExt;
import 'comment_badge.dart';
import 'reader_text_indent.dart';

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
    this.letterSpacing,
    this.badgeGap,
    this.badgeCompact = false,
  });

  final ParagraphContent source;
  final int paragraphIndex;
  final String paragraphId;
  final int? startOffset;
  final int? endOffset;
  final double? letterSpacing;
  final double? badgeGap;

  /// Whether this paragraph's badge resolved to the compact icon-only
  /// capsule (see [CommentParagraphLayout.compact]).
  final bool badgeCompact;

  String get visibleText {
    final full = switch (source) {
      ParagraphContent_Text(:final content) => content,
      ParagraphContent_Title(:final text) => text,
      _ => '',
    };
    final s = startOffset ?? 0;
    final e = endOffset ?? full.length;
    return full.substring(s, e);
  }

  bool get isPartial => startOffset != null || endOffset != null;
}

class PageContent {
  const PageContent({
    required this.items,
    this.chapterId = '',
    this.extraGap = 0,
  });

  final List<PageItem> items;

  /// Chapter this page belongs to (set by the content manager when pages
  /// from several chapters are concatenated into one list).
  final String chapterId;

  /// Extra height the renderer adds to every inter-item gap so the page
  /// fills to its bottom edge — this page's leftover space, distributed
  /// across its gaps (typeset vertical justification). Set only on pages
  /// that broke because the next *text* chunk would not fit; the chapter's
  /// final page and pages before blocks kept whole (titles, images) keep
  /// their natural trailing space instead, since their break is deliberate.
  final double extraGap;

  int get firstParagraphIndex => items.isEmpty ? 0 : items.first.paragraphIndex;
  String get firstParagraphId => items.isEmpty ? '' : items.first.paragraphId;

  /// Character offset of the page-leading character within its paragraph
  /// (0 when the page starts at a paragraph boundary).
  int get firstCharOffset {
    final item = items.isEmpty ? null : items.first;
    if (item == null) return 0;
    if (item.source is ParagraphContent_Text ||
        item.source is ParagraphContent_Title) {
      return item.startOffset ?? 0;
    }
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
    this.textScaler = TextScaler.noScaling,
    this.locale,
  });

  final Size pageSize;
  final TextStyle textStyle;
  final TextStyle titleStyle;
  final double paragraphSpacing;
  final double imageHeight;
  final ui.TextDirection textDirection;
  final TextScaler textScaler;
  final Locale? locale;

  /// Paginates [items] synchronously to completion.
  ///
  /// Entering the reader must never block a build on this — a full chapter
  /// of TextPainter work — so the horizontal reader uses [startPagination]
  /// and steps the job across frames instead. This synchronous form remains
  /// for callers that need the final result now (the vertical reader's
  /// restore estimate) and for tests.
  List<PageContent> computePages(
    List<ParagraphContent> items, {
    String chapterId = '',
    Map<String, Size> commentBadgeSizes = const {},
  }) {
    if (items.isEmpty) return const [];
    final job = startPagination(
      items,
      chapterId: chapterId,
      commentBadgeSizes: commentBadgeSizes,
    );
    while (!job.step(const Duration(seconds: 10))) {}
    return job.result;
  }

  /// Starts an incremental pagination job over one chapter.
  ///
  /// [commentBadgeSizeOf] resolves a paragraph's badge size lazily, as the
  /// paragraph is reached; [commentBadgeSizes] is the pre-measured form.
  /// Lazy resolution lets a chunked pagination spread badge measurements
  /// across slices instead of paying for the whole table up front.
  PaginationJob startPagination(
    List<ParagraphContent> items, {
    String chapterId = '',
    Map<String, Size> commentBadgeSizes = const {},
    Size? Function(String paragraphId)? commentBadgeSizeOf,
  }) {
    return PaginationJob(
      breaker: this,
      items: items,
      chapterId: chapterId,
      commentBadgeSizes: commentBadgeSizes,
      commentBadgeSizeOf: commentBadgeSizeOf,
    );
  }

  double _measureText(
    String text,
    TextStyle style,
    TextAlign align,
    double width,
    Size? badgeSize, [
    double firstLineIndent = 0,
  ]) {
    final painter = _textPainter(
      text,
      style,
      align,
      width,
      badgeSize,
      firstLineIndent,
    );
    final height = painter.height;
    painter.dispose();
    return height;
  }

  TextPainter _textPainter(
    String text,
    TextStyle style,
    TextAlign align,
    double width,
    Size? badgeSize, [
    double firstLineIndent = 0,
  ]) {
    final indentWidth = BadgedText.indentWidth(
      text: text,
      style: style,
      scaler: textScaler,
      maxWidth: width,
      em: firstLineIndent,
      direction: textDirection,
      locale: locale,
      badgeSize: badgeSize,
    );
    final fontSize = style.fontSize ?? 14;
    final scale = fontSize == 0 ? 0.0 : textScaler.scale(fontSize) / fontSize;
    final painter = TextPainter(
      text: ReaderTextIndent.span(
        badgeSize == null
            ? TextSpan(text: text, style: style)
            : BadgedText.inlineSpan(text, style, const SizedBox.shrink()),
        indentWidth,
      ),
      textDirection: textDirection,
      textAlign: align,
      textScaler: textScaler,
      locale: locale,
    );
    if (badgeSize != null || indentWidth > 0) {
      painter.setPlaceholderDimensions([
        if (indentWidth > 0) ReaderTextIndent.dimensions(indentWidth, scale),
        if (badgeSize != null)
          BadgedText.tailDimensions(
            text,
            style,
            badgeSize,
            textDirection,
            locale,
            scale: scale,
          ),
      ]);
    }
    painter.layout(maxWidth: width);
    return painter;
  }

  void _layoutText({
    required String chapterId,
    required String text,
    required int paragraphIndex,
    required String paragraphId,
    required ParagraphContent source,
    required TextStyle style,
    required TextAlign textAlign,
    double firstLineIndent = 0,
    Size? badgeSize,
    double? badgeGap,
    bool badgeCompact = false,
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
    final tp = _textPainter(
      text,
      style,
      textAlign,
      width,
      badgeSize,
      firstLineIndent,
    );
    final indentPrefix =
        BadgedText.indentWidth(
              text: text,
              style: style,
              scaler: textScaler,
              maxWidth: width,
              em: firstLineIndent,
              direction: textDirection,
              locale: locale,
              badgeSize: badgeSize,
            ) >
            0
        ? 1
        : 0;

    final lineMetrics = tp.computeLineMetrics();
    // Suffix sums of line heights: "does the rest of the paragraph fit?"
    // in O(1).
    final suffixHeights = List<double>.filled(lineMetrics.length + 1, 0);
    for (var i = lineMetrics.length - 1; i >= 0; i--) {
      suffixHeights[i] = suffixHeights[i + 1] + lineMetrics[i].height;
    }

    double spacingFor(List<PageItem> items) =>
        items.isEmpty ? 0.0 : paragraphSpacing;

    // Closes the current page, distributing [leftover] — the space the next
    // text chunk could not use — into the page's gaps so it fills to its
    // bottom. Only text-driven breaks do this; see [PageContent.extraGap].
    void closeJustified(double leftover) {
      final gaps = currentItems.length - 1;
      // A paragraph that renders its comment badge can lay out a few pixels
      // taller than any TextPainter pre-measurement of the same span reports:
      // even when handed the placeholder's exact dimensions, SkParagraph's
      // real inline-child layout (the first layout of a baseline-aligned
      // WidgetSpan) pushes the badge line down by up to about a quarter of
      // the scaled font size. Hold that much of the leftover back per
      // badge-rendering item so the stretched gaps can never push real
      // content past the page host; badge-free pages measure exactly and
      // stretch to the full leftover.
      const badgeLineSlackEm = 0.25;
      var slack = leftover;
      for (final item in currentItems) {
        if (item.badgeGap == null || item.endOffset != null) continue;
        final font =
            (item.source is ParagraphContent_Title
                ? titleStyle.fontSize
                : textStyle.fontSize) ??
            0;
        slack -= badgeLineSlackEm * textScaler.scale(font);
      }
      final extra = gaps > 0 && slack > 0 ? slack / gaps : 0.0;
      pages.add(
        PageContent(chapterId: chapterId, items: currentItems, extraGap: extra),
      );
    }

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
            letterSpacing: badgeGap == null ? null : style.letterSpacing,
            badgeGap: badgeGap,
            badgeCompact: badgeCompact,
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
      // Only remeasure a suffix near the page boundary. Long badged
      // paragraphs still shape once instead of reshaping every suffix.
      final needsExactTail =
          badgeSize != null &&
          suffixHeights[lineIdx] <= space + lineMetrics[lineIdx].height;
      final restHeight = !needsExactTail
          ? suffixHeights[lineIdx]
          : charStart == 0
          ? tp.height
          : _measureText(
              text.substring(charStart),
              style,
              textAlign,
              width,
              badgeSize,
            );
      if (space >= restHeight) {
        tp.dispose();
        remainingSpace -= sp + restHeight;
        currentItems.add(
          PageItem(
            source: source,
            paragraphIndex: paragraphIndex,
            paragraphId: paragraphId,
            startOffset: charStart == 0 ? null : charStart,
            letterSpacing: badgeGap == null ? null : style.letterSpacing,
            badgeGap: badgeGap,
            badgeCompact: badgeCompact,
          ),
        );
        onUpdate(currentItems, remainingSpace);
        return;
      }

      if (space <= 0 ||
          (space < lineMetrics[lineIdx].height && currentItems.isNotEmpty)) {
        closeJustified(remainingSpace);
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
          closeJustified(remainingSpace);
          currentItems = [];
          remainingSpace = pageHeight;
          continue;
        }
        fitLines = 1;
      }

      int splitFor(int lines) {
        final lastLine = lineMetrics[lineIdx + lines - 1];
        final bottom = lastLine.baseline + lastLine.descent;
        return (tp.getPositionForOffset(Offset(width, bottom - 1)).offset -
                indentPrefix)
            .clamp(charStart + 1, text.length);
      }

      if (badgeSize != null) {
        // Reserve the final rich-text line: its tail text and badge must
        // move to the next page together, never as an orphan badge.
        final prefixLines = lineMetrics.length - lineIdx - 1;
        if (prefixLines == 0 && currentItems.isNotEmpty) {
          closeJustified(remainingSpace);
          currentItems = [];
          remainingSpace = pageHeight;
          continue;
        }
        if (prefixLines == 0) {
          // A single line taller than the entire viewport cannot be split.
          currentItems.add(
            PageItem(
              source: source,
              paragraphIndex: paragraphIndex,
              paragraphId: paragraphId,
              startOffset: charStart == 0 ? null : charStart,
              letterSpacing: badgeGap == null ? null : style.letterSpacing,
              badgeGap: badgeGap,
              badgeCompact: badgeCompact,
            ),
          );
          remainingSpace -= sp + restHeight;
          break;
        }
        fitLines = fitLines.clamp(1, prefixLines);
        var low = 1, high = fitLines, best = 0;
        while (low <= high) {
          final middle = (low + high) ~/ 2;
          final height = _measureText(
            text.substring(charStart, splitFor(middle)),
            style,
            textAlign,
            width,
            null,
            charStart == 0 ? firstLineIndent : 0,
          );
          if (height <= space) {
            best = middle;
            low = middle + 1;
          } else {
            high = middle - 1;
          }
        }
        if (best == 0 && currentItems.isNotEmpty) {
          closeJustified(remainingSpace);
          currentItems = [];
          remainingSpace = pageHeight;
          continue;
        }
        fitLines = best == 0 ? 1 : best;
      }
      var splitChar = splitFor(fitLines);
      if (splitChar <= charStart) splitChar = charStart + 1;
      if (splitChar > text.length) splitChar = text.length;

      currentItems.add(
        PageItem(
          source: source,
          paragraphIndex: paragraphIndex,
          paragraphId: paragraphId,
          startOffset: charStart == 0 ? null : charStart,
          endOffset: splitChar,
          letterSpacing: badgeGap == null ? null : style.letterSpacing,
          badgeGap: badgeGap,
          badgeCompact: badgeCompact,
        ),
      );

      // The fragment consumed `sp` plus its `accH` of lines; whatever the
      // page could not spend on them is its leftover.
      closeJustified(remainingSpace - sp - accH);
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

// ─────────────────────────────────────────────────────────────────────────────
// Incremental pagination
// ─────────────────────────────────────────────────────────────────────────────

/// Resumable [PageBreaker] pagination over one chapter.
///
/// [PageBreaker.computePages] runs a job to completion in one synchronous
/// burst. The horizontal reader cannot afford that on the UI thread when
/// several chapters arrive at once (entering the reader), so it steps a job
/// with a per-frame time budget instead: each [step] processes at least one
/// paragraph and keeps going until the budget elapses.
///
/// [pages] is append-only — callers may read it between steps and see a
/// stable prefix that only ever grows, so a partially paginated chapter can
/// display what exists while the rest is still being computed. The finest
/// granularity is one paragraph: a single pathological paragraph can exceed
/// the budget by itself, because its badge fitting probes several layouts.
class PaginationJob {
  PaginationJob({
    required PageBreaker breaker,
    required List<ParagraphContent> items,
    this.chapterId = '',
    Map<String, Size> commentBadgeSizes = const {},
    Size? Function(String paragraphId)? commentBadgeSizeOf,
  }) : _breaker = breaker,
       _items = items,
       _badgeSizeOf = commentBadgeSizeOf ?? ((id) => commentBadgeSizes[id]) {
    final height = breaker.pageSize.height - 4.0;
    if (breaker.pageSize.width <= 0 || height <= 0) {
      // Degenerate geometry: emit everything on one page, like computePages.
      _degenerate = true;
    } else {
      _remaining = height;
    }
  }

  final PageBreaker _breaker;
  final List<ParagraphContent> _items;

  /// Badge size per paragraph id, measured on demand.
  final Size? Function(String paragraphId) _badgeSizeOf;

  /// The chapter these pages belong to.
  final String chapterId;

  /// Pages emitted so far. Append-only while the job runs.
  final List<PageContent> pages = [];

  List<PageItem> _current = [];
  double _remaining = 0;
  int _index = 0;
  bool _degenerate = false;
  bool _done = false;

  bool get isDone => _done;

  /// Processes at least one paragraph, then continues until [budget] elapses
  /// or the chapter completes. Returns `true` once fully paginated.
  bool step(Duration budget) {
    if (_done) return true;
    if (_degenerate) {
      _done = true;
      if (_items.isNotEmpty) {
        pages.add(_allItemsPage());
      }
      return true;
    }
    final watch = Stopwatch()..start();
    do {
      _processNext();
    } while (!_done && watch.elapsed < budget);
    return _done;
  }

  /// The completed pagination result — [pages], or the single all-items page
  /// when nothing fit.
  List<PageContent> get result =>
      pages.isEmpty && _items.isNotEmpty ? [_allItemsPage()] : pages;

  PageContent _allItemsPage() => PageContent(
    chapterId: chapterId,
    items: [
      for (var i = 0; i < _items.length; i++)
        PageItem(
          source: _items[i],
          paragraphIndex: i,
          paragraphId: _items[i].id.toStringValue(),
        ),
    ],
  );

  void _processNext() {
    if (_index >= _items.length) {
      if (_current.isNotEmpty) {
        // The chapter's final page ends where its content does — no
        // justification.
        pages.add(PageContent(chapterId: chapterId, items: _current));
        _current = [];
      }
      _done = true;
      return;
    }

    final i = _index++;
    final item = _items[i];
    var badgeSize = _badgeSizeOf(item.id.toStringValue());
    var style = item is ParagraphContent_Title
        ? _breaker.titleStyle
        : _breaker.textStyle;
    CommentParagraphLayout? badgeLayout;
    if (badgeSize != null &&
        (item is ParagraphContent_Text || item is ParagraphContent_Title)) {
      badgeLayout = CommentParagraphLayout.resolve(
        text: item is ParagraphContent_Text
            ? item.content
            : (item as ParagraphContent_Title).text,
        style: style,
        badgeSize: badgeSize,
        width: _breaker.pageSize.width,
        textScaler: _breaker.textScaler,
        direction: _breaker.textDirection,
        locale: _breaker.locale,
        align: item is ParagraphContent_Title
            ? TextAlign.center
            : TextAlign.start,
        firstLineIndent: item is ParagraphContent_Text
            ? item.layout.firstLineIndent.toDouble()
            : 0,
      );
      style = badgeLayout.style;
      badgeSize = badgeLayout.badgeSize(badgeSize);
    }

    final width = _breaker.pageSize.width;
    final pageHeight = _breaker.pageSize.height - 4.0;
    final spacing = _current.isEmpty ? 0.0 : _breaker.paragraphSpacing;

    if (item is ParagraphContent_Title) {
      final height = _breaker._measureText(
        item.text,
        style,
        TextAlign.center,
        width,
        badgeSize,
      );
      // Keep ordinary headings together. Only headings taller than an entire
      // page need the same continuation logic as body paragraphs.
      if (height <= pageHeight) {
        if (_remaining - spacing < height && _current.isNotEmpty) {
          // Not justified: the kept-whole title starts the next page by
          // design, so this page's trailing space is a deliberate break.
          pages.add(PageContent(chapterId: chapterId, items: _current));
          _current = [];
          _remaining = pageHeight;
        }
        _remaining -=
            (_current.isEmpty ? 0 : _breaker.paragraphSpacing) + height;
        _current.add(
          PageItem(
            source: item,
            paragraphIndex: i,
            paragraphId: item.id.toStringValue(),
            letterSpacing: badgeLayout?.style.letterSpacing,
            badgeGap: badgeLayout?.gap,
            badgeCompact: badgeLayout?.compact ?? false,
          ),
        );
        return;
      }
    }

    if (item is ParagraphContent_Title || item is ParagraphContent_Text) {
      _breaker._layoutText(
        chapterId: chapterId,
        text: switch (item) {
          ParagraphContent_Title(:final text) => text,
          ParagraphContent_Text(:final content) => content,
          _ => throw StateError('Expected text or title'),
        },
        style: style,
        firstLineIndent: item is ParagraphContent_Text
            ? item.layout.firstLineIndent.toDouble()
            : 0,
        badgeGap: badgeLayout?.gap,
        badgeCompact: badgeLayout?.compact ?? false,
        textAlign: item is ParagraphContent_Title
            ? TextAlign.center
            : TextAlign.start,
        badgeSize: badgeSize,
        paragraphIndex: i,
        paragraphId: item.id.toStringValue(),
        source: item,
        width: width,
        pageHeight: pageHeight,
        remaining: _remaining,
        currentItems: _current,
        pages: pages,
        onUpdate: (newItems, newRemaining) {
          _current = newItems;
          _remaining = newRemaining;
        },
      );
    } else if (item is ParagraphContent_Image) {
      if (_remaining - spacing < _breaker.imageHeight && _current.isNotEmpty) {
        // Not justified, like titles: the kept-whole image starts the next
        // page by design.
        pages.add(PageContent(chapterId: chapterId, items: _current));
        _current = [];
        _remaining = pageHeight;
      }
      final sp = _current.isEmpty ? 0.0 : _breaker.paragraphSpacing;
      _remaining -= sp + _breaker.imageHeight;
      _current.add(
        PageItem(
          source: item,
          paragraphIndex: i,
          paragraphId: item.id.toStringValue(),
        ),
      );
    }
  }
}

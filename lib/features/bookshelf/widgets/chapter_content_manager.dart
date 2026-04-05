import 'package:flutter/material.dart';

import '../../feeds/feed_service.dart';
import 'horizontal_reader_view.dart';
import 'vertical_reader_view.dart';

enum ReaderMode { verticalScroll, horizontalPaging }

// ─────────────────────────────────────────────────────────────────────────────
// ChapterContentManager Widget (Thin Wrapper)
// ─────────────────────────────────────────────────────────────────────────────

/// Thin wrapper that switches between VerticalReaderView and HorizontalReaderView
/// based on the reading mode. Maintains stable controller lifecycle across mode switches.
class ChapterContentManager extends StatefulWidget {
  const ChapterContentManager({
    super.key,
    required this.feedId,
    required this.bookId,
    required this.chapters,
    required this.initialChapterId,
    required this.initialParagraphIndex,
    required this.readerMode,
    required this.contentPadding,
    required this.onChapterChanged,
    required this.onParagraphChanged,
  });

  final String feedId;
  final String bookId;
  final List<ChapterInfoModel> chapters;
  final String initialChapterId;
  final int initialParagraphIndex;
  final ReaderMode readerMode;
  final EdgeInsets contentPadding;
  final ValueChanged<String> onChapterChanged;
  final ValueChanged<int> onParagraphChanged;

  @override
  State<ChapterContentManager> createState() => _ChapterContentManagerState();
}

class _ChapterContentManagerState extends State<ChapterContentManager> {
  @override
  Widget build(BuildContext context) {
    if (widget.readerMode == ReaderMode.verticalScroll) {
      return VerticalReaderView(
        feedId: widget.feedId,
        bookId: widget.bookId,
        chapters: widget.chapters,
        initialChapterId: widget.initialChapterId,
        initialParagraphIndex: widget.initialParagraphIndex,
        contentPadding: widget.contentPadding,
        onChapterChanged: widget.onChapterChanged,
        onParagraphChanged: widget.onParagraphChanged,
      );
    } else {
      return HorizontalReaderView(
        feedId: widget.feedId,
        bookId: widget.bookId,
        chapters: widget.chapters,
        initialChapterId: widget.initialChapterId,
        initialParagraphIndex: widget.initialParagraphIndex,
        contentPadding: widget.contentPadding,
        onChapterChanged: widget.onChapterChanged,
        onParagraphChanged: widget.onParagraphChanged,
      );
    }
  }
}

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import 'reader_types.dart';

/// The reader's persistent, transparent status line along the bottom edge.
///
/// * left — the current chapter title, ellipsised when long;
/// * right — chapter progress (`page / total`) plus whole-book progress.
///
/// It rides directly on the reading surface with no background of its own
/// and fades out while the control bars are up (the solid bottom bar would
/// cover it). Reading content never scrolls beneath it: the reader reserves
/// [reservedHeight] plus the safe-area inset at the bottom of its content
/// area, and the vertical reader's viewport is inset likewise.
class ReaderStatusBar extends StatelessWidget {
  const ReaderStatusBar({
    super.key,
    required this.visible,
    required this.theme,
    required this.chapterId,
    required this.chapterTitle,
    required this.chapterIndex,
    required this.chapterCount,
    required this.pageProgress,
  });

  /// Whether the line renders — hidden while the reader controls are up.
  final bool visible;

  final ThemeData theme;

  /// Source id of the chapter the reader is showing. Page progress is only
  /// applied when it addresses this chapter, so a progress value left over
  /// from the previous chapter during a turn never leaks into the label.
  final String chapterId;

  final String chapterTitle;

  /// 0-based index of the visible chapter within the book.
  final int chapterIndex;

  final int chapterCount;

  /// Live page progress of the active chapter (horizontal mode); null in
  /// vertical mode and while the target page is unresolved.
  final ValueListenable<ReaderPageProgress?> pageProgress;

  /// Line box of the status text (labelSmall ≈ 16 logical px).
  static const lineHeight = 16.0;

  /// Gap between the status line and the bottom safe-area edge.
  static const bottomGap = LanghuanTheme.spaceXs;

  /// Gap kept between the reading content and the status line.
  static const contentGap = LanghuanTheme.spaceSm;

  /// Bottom space the bar keeps free of reading content, excluding the
  /// safe-area inset (the caller adds `MediaQuery.viewPadding.bottom`).
  static const reservedHeight = lineHeight + bottomGap + contentGap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      // Purely informational: taps must keep reaching the reading surface.
      child: IgnorePointer(
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 180),
          opacity: visible ? 1 : 0,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              LanghuanTheme.spaceLg,
              0,
              LanghuanTheme.spaceLg,
              bottomInset + bottomGap,
            ),
            child: SizedBox(
              height: lineHeight,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      chapterTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: style,
                    ),
                  ),
                  const SizedBox(width: LanghuanTheme.spaceSm),
                  ValueListenableBuilder<ReaderPageProgress?>(
                    valueListenable: pageProgress,
                    builder: (context, progress, _) {
                      return Text(
                        _trailingLabel(l10n, progress),
                        maxLines: 1,
                        style: style,
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _trailingLabel(AppLocalizations l10n, ReaderPageProgress? progress) {
    final percent = _bookPercent(progress);
    final applies = progress != null && progress.chapterId == chapterId;
    return applies
        ? '${l10n.readerPageProgress(progress.pageIndex + 1, progress.pageCount)} · ${l10n.readerBookProgress(percent)}'
        : l10n.readerBookProgress(percent);
  }

  /// Whole-book progress as a percentage. Chapter granularity plus, in
  /// horizontal mode, the page fraction within the chapter — the same
  /// formula the bookshelf progress uses at paragraph granularity.
  int _bookPercent(ReaderPageProgress? progress) {
    if (chapterCount <= 0) return 0;
    var intraChapter = 0.0;
    if (progress != null && progress.chapterId == chapterId) {
      intraChapter = ((progress.pageIndex + 1) / progress.pageCount).clamp(
        0.0,
        1.0,
      );
    }
    final value = ((chapterIndex + intraChapter) / chapterCount).clamp(
      0.0,
      1.0,
    );
    return (value * 100).round();
  }
}

import 'dart:ui';

import '../../../src/rust/api/types.dart';

export '../../../shared/utils/errors.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Paragraph selection — long-pressed paragraph info for toolbar overlay
// ─────────────────────────────────────────────────────────────────────────────

class ParagraphSelection {
  const ParagraphSelection({
    required this.chapterId,
    required this.paragraphId,
    required this.paragraph,
    required this.rect,
  });

  final String chapterId;
  final String paragraphId;
  final ParagraphContent paragraph;
  final Rect rect;
}

// ─────────────────────────────────────────────────────────────────────────────
// Page progress — reported from the content manager to the reader chrome
// ─────────────────────────────────────────────────────────────────────────────

/// The active chapter's live page position (horizontal mode).
///
/// Published by [ChapterContentManager] through a parent-supplied
/// [ValueNotifier] so the reader status bar can show `current/total` page
/// progress without rebuilding the whole reader on every page turn. The
/// page count is final once the chapter's pagination job completes; while
/// the job runs, values are provisional and the count only grows.
class ReaderPageProgress {
  const ReaderPageProgress({
    required this.chapterId,
    required this.pageIndex,
    required this.pageCount,
  });

  final String chapterId;

  /// 0-based index of the active page within its chapter.
  final int pageIndex;

  /// Page count of the chapter (final after pagination completes).
  final int pageCount;

  @override
  bool operator ==(Object other) =>
      other is ReaderPageProgress &&
      other.chapterId == chapterId &&
      other.pageIndex == pageIndex &&
      other.pageCount == pageCount;

  @override
  int get hashCode => Object.hash(chapterId, pageIndex, pageCount);

  @override
  String toString() =>
      'ReaderPageProgress($chapterId, ${pageIndex + 1}/$pageCount)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Chapter load state — sealed hierarchy
// ─────────────────────────────────────────────────────────────────────────────

sealed class ChapterLoadState {
  const ChapterLoadState();
}

final class ChapterIdle extends ChapterLoadState {
  const ChapterIdle();
}

final class ChapterLoading extends ChapterLoadState {
  const ChapterLoading();
}

final class ChapterLoaded extends ChapterLoadState {
  const ChapterLoaded(this.paragraphs);
  final List<ParagraphContent> paragraphs;
}

final class ChapterLoadError extends ChapterLoadState {
  const ChapterLoadError({required this.error});
  final Object error;
}

// ─────────────────────────────────────────────────────────────────────────────
// Error normalisation
// ─────────────────────────────────────────────────────────────────────────────

ErrorKind? extractErrorKind(Object? error) {
  if (error is BridgeError) return error.kind;
  return null;
}

bool isAuthRequiredError(Object? error) {
  final kind = extractErrorKind(error);
  return kind is ErrorKind_ScriptExpected &&
      kind.reason is ScriptExpectedReason_AuthRequired;
}

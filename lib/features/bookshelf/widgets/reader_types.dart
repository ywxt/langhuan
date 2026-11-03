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
// Chapter progress — reported from the content manager to the reader chrome
// ─────────────────────────────────────────────────────────────────────────────

/// What the position within a chapter is counted in: pages (horizontal
/// mode) or paragraphs (vertical mode).
enum ReaderProgressUnit { page, paragraph }

/// The active chapter's live position.
///
/// Published by [ChapterContentManager] through a parent-supplied
/// [ValueNotifier] so the reader status bar can show `current/total`
/// progress without rebuilding the whole reader on every page turn.
///
/// * horizontal mode — [unit] is [ReaderProgressUnit.page]; the count is
///   final once the chapter's pagination job completes, and provisional
///   while it runs (the count only grows).
/// * vertical mode — [unit] is [ReaderProgressUnit.paragraph], the same
///   granularity the bookshelf's whole-book percentage uses, so both
///   surfaces agree on one reading position.
class ReaderChapterProgress {
  const ReaderChapterProgress({
    required this.chapterId,
    required this.unitIndex,
    required this.unitCount,
    this.unit = ReaderProgressUnit.page,
  });

  final String chapterId;

  /// What [unitIndex] and [unitCount] count.
  final ReaderProgressUnit unit;

  /// 0-based index of the active page or paragraph within its chapter.
  final int unitIndex;

  /// Page or paragraph count of the chapter.
  final int unitCount;

  @override
  bool operator ==(Object other) =>
      other is ReaderChapterProgress &&
      other.chapterId == chapterId &&
      other.unit == unit &&
      other.unitIndex == unitIndex &&
      other.unitCount == unitCount;

  @override
  int get hashCode => Object.hash(chapterId, unit, unitIndex, unitCount);

  @override
  String toString() =>
      'ReaderChapterProgress($chapterId, ${unitIndex + 1}/$unitCount ${unit.name})';
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

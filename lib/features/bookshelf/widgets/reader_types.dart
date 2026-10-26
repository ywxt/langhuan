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

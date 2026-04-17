import '../../../src/rust/api/types.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Chapter direction
// ─────────────────────────────────────────────────────────────────────────────

enum ChapterDirection { previous, next }

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
  const ChapterLoadError({required this.error, required this.message});
  final Object error;
  final String message;
}

// ─────────────────────────────────────────────────────────────────────────────
// Error normalisation
// ─────────────────────────────────────────────────────────────────────────────

String normalizeErrorMessage(Object error) {
  final text = error.toString().trim();
  if (text.isEmpty) return 'Unknown error';
  final colonIndex = text.indexOf(':');
  if (colonIndex > 0 && colonIndex < text.length - 1) {
    return text.substring(colonIndex + 1).trim();
  }
  return text;
}

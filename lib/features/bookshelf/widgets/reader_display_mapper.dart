import '../../../l10n/app_localizations.dart';
import '../../../src/bindings/signals/signals.dart';
import 'reader_types.dart';

/// UI-ready chapter entry derived from a [ChapterSlot].
///
/// Both vertical and horizontal reader views consume this unified model to avoid
/// duplicating state checks and error formatting logic.
enum ChapterDisplayKind { loading, success, error }

class ChapterDisplayEntry {
  final String chapterId;
  final int chapterIndex;
  final String title;
  final ChapterDisplayKind kind;
  final List<ParagraphContent> content;
  final String? errorMessage;

  const ChapterDisplayEntry._({
    required this.chapterId,
    required this.chapterIndex,
    required this.title,
    required this.kind,
    this.content = const [],
    this.errorMessage,
  });

  const ChapterDisplayEntry.loading({
    required String chapterId,
    required int chapterIndex,
    required String title,
  }) : this._(
         chapterId: chapterId,
         chapterIndex: chapterIndex,
         title: title,
         kind: ChapterDisplayKind.loading,
       );

  const ChapterDisplayEntry.success({
    required String chapterId,
    required int chapterIndex,
    required String title,
    required List<ParagraphContent> content,
  }) : this._(
         chapterId: chapterId,
         chapterIndex: chapterIndex,
         title: title,
         kind: ChapterDisplayKind.success,
         content: content,
       );

  const ChapterDisplayEntry.error({
    required String chapterId,
    required int chapterIndex,
    required String title,
    required String errorMessage,
  }) : this._(
         chapterId: chapterId,
         chapterIndex: chapterIndex,
         title: title,
         kind: ChapterDisplayKind.error,
         errorMessage: errorMessage,
       );
}

List<ChapterDisplayEntry> buildChapterDisplayEntries({
  required List<ChapterSlot> slots,
  required AppLocalizations l10n,
}) {
  final entries = <ChapterDisplayEntry>[];

  for (final slot in slots) {
    final fallbackTitle = l10n.readerChapterFallbackTitle(
      slot.chapterIndex + 1,
    );
    final paragraphs = slot.paragraphs;

    if (paragraphs != null) {
      final title = _resolveTitle(paragraphs, fallbackTitle);
      entries.add(
        ChapterDisplayEntry.success(
          chapterId: slot.chapterId,
          chapterIndex: slot.chapterIndex,
          title: title,
          content: paragraphs,
        ),
      );
      continue;
    }

    if (slot.isLoading) {
      entries.add(
        ChapterDisplayEntry.loading(
          chapterId: slot.chapterId,
          chapterIndex: slot.chapterIndex,
          title: fallbackTitle,
        ),
      );
      continue;
    }

    if (slot.isError) {
      entries.add(
        ChapterDisplayEntry.error(
          chapterId: slot.chapterId,
          chapterIndex: slot.chapterIndex,
          title: fallbackTitle,
          errorMessage: slot.errorMessage ?? l10n.readerChapterLoadError,
        ),
      );
    }
  }

  return entries;
}

String _resolveTitle(List<ParagraphContent> content, String fallback) {
  if (content.isNotEmpty && content.first is ParagraphContentTitle) {
    return (content.first as ParagraphContentTitle).text;
  }
  return fallback;
}

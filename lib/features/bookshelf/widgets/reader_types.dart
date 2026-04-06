import 'package:flutter/foundation.dart';

import '../../../src/bindings/signals/signals.dart';
import '../../feeds/feed_service.dart';
import 'page_breaker.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Chapter load state
// ─────────────────────────────────────────────────────────────────────────────

/// Sealed hierarchy representing the load state of a single chapter.
sealed class ChapterLoadState {
  const ChapterLoadState();
}

final class ChapterIdle extends ChapterLoadState {
  const ChapterIdle();
}

final class ChapterLoading extends ChapterLoadState {
  const ChapterLoading();
}

final class ChapterReady extends ChapterLoadState {
  const ChapterReady(this.paragraphs);
  final List<ParagraphContent> paragraphs;
}

final class ChapterError extends ChapterLoadState {
  const ChapterError({required this.error, required this.message});
  final Object error;
  final String message;
}

// ─────────────────────────────────────────────────────────────────────────────
// Chapter slot
// ─────────────────────────────────────────────────────────────────────────────

/// Holds the state for one chapter in the loaded window.
///
/// Immutable value object — a new instance is created on every state change.
@immutable
class ChapterSlot {
  const ChapterSlot({
    required this.chapterId,
    required this.chapterIndex,
    required this.state,
    this.pages = const [],
    this.requestId,
  });

  final String chapterId;
  final int chapterIndex;
  final ChapterLoadState state;

  /// Pre-computed pages for horizontal mode. Empty until computed.
  final List<PageContent> pages;

  /// Request ID for cancellation via [FeedService].
  final String? requestId;

  // ─ Convenience getters ───────────────────────────────────────────────────

  List<ParagraphContent>? get paragraphs =>
      state is ChapterReady ? (state as ChapterReady).paragraphs : null;

  bool get isLoading => state is ChapterLoading;
  bool get isReady => state is ChapterReady;
  bool get isError => state is ChapterError;

  Object? get error =>
      state is ChapterError ? (state as ChapterError).error : null;
  String? get errorMessage =>
      state is ChapterError ? (state as ChapterError).message : null;

  // ─ Copy-with helpers ─────────────────────────────────────────────────────

  ChapterSlot copyWith({
    ChapterLoadState? state,
    List<PageContent>? pages,
    String? requestId,
  }) {
    return ChapterSlot(
      chapterId: chapterId,
      chapterIndex: chapterIndex,
      state: state ?? this.state,
      pages: pages ?? this.pages,
      requestId: requestId ?? this.requestId,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Error normalisation
// ─────────────────────────────────────────────────────────────────────────────

/// Extracts a human-readable message from an error object.
String normalizeChapterErrorMessage(Object error) {
  if (error is FeedStreamException) return error.message;

  final text = error.toString().trim();
  if (text.isEmpty) return 'Unknown error';

  final colonIndex = text.indexOf(':');
  if (colonIndex > 0 && colonIndex < text.length - 1) {
    return text.substring(colonIndex + 1).trim();
  }
  return text;
}

// ─────────────────────────────────────────────────────────────────────────────
// Reader mode
// ─────────────────────────────────────────────────────────────────────────────

enum ReaderMode { verticalScroll, horizontalPaging }

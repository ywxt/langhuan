import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/widgets/reader_display_mapper.dart';
import 'package:langhuan/features/bookshelf/widgets/reader_types.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import 'package:langhuan/src/rust/api/types.dart';

void main() {
  group('buildChapterDisplayEntries', () {
    testWidgets('maps loading, success, and error slots into display entries', (
      tester,
    ) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      const loadingSlot = ChapterSlot(
        chapterId: 'c1',
        chapterIndex: 0,
        state: ChapterLoading(),
      );

      const successSlot = ChapterSlot(
        chapterId: 'c2',
        chapterIndex: 1,
        state: ChapterReady([
          ParagraphContent_Title(text: 'Chapter Two'),
          ParagraphContent_Text(content: 'Body'),
        ]),
      );

      final errorSlot = ChapterSlot(
        chapterId: 'c3',
        chapterIndex: 2,
        state: ChapterError(
          error: Exception('network broken'),
          message: 'network broken',
        ),
      );

      final entries = buildChapterDisplayEntries(
        slots: [loadingSlot, successSlot, errorSlot],
        l10n: l10n,
      );

      expect(entries, hasLength(3));

      expect(entries[0].kind, ChapterDisplayKind.loading);
      expect(entries[0].title, 'Chapter 1');

      expect(entries[1].kind, ChapterDisplayKind.success);
      expect(entries[1].title, 'Chapter Two');
      expect(entries[1].content, hasLength(2));

      expect(entries[2].kind, ChapterDisplayKind.error);
      expect(entries[2].title, 'Chapter 3');
      expect(entries[2].errorMessage, 'network broken');
    });

    testWidgets('uses fallback title when first paragraph is not a title', (
      tester,
    ) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      const slot = ChapterSlot(
        chapterId: 'c1',
        chapterIndex: 4,
        state: ChapterReady([ParagraphContent_Text(content: 'No title here')]),
      );

      final entries = buildChapterDisplayEntries(slots: [slot], l10n: l10n);

      expect(entries, hasLength(1));
      expect(entries[0].title, 'Chapter 5'); // index 4 + 1
    });

    testWidgets('returns empty list for empty slots', (tester) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      final entries = buildChapterDisplayEntries(slots: const [], l10n: l10n);

      expect(entries, isEmpty);
    });

    testWidgets('skips idle slots', (tester) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      const slot = ChapterSlot(
        chapterId: 'c1',
        chapterIndex: 0,
        state: ChapterIdle(),
      );

      final entries = buildChapterDisplayEntries(slots: [slot], l10n: l10n);

      expect(entries, isEmpty);
    });
  });

  group('ChapterDisplayEntry', () {
    test('loading factory', () {
      const entry = ChapterDisplayEntry.loading(
        chapterId: 'c1',
        chapterIndex: 0,
        title: 'Chapter 1',
      );
      expect(entry.kind, ChapterDisplayKind.loading);
      expect(entry.content, isEmpty);
      expect(entry.errorMessage, isNull);
    });

    test('success factory', () {
      const entry = ChapterDisplayEntry.success(
        chapterId: 'c2',
        chapterIndex: 1,
        title: 'My Chapter',
        content: [ParagraphContent_Text(content: 'text')],
      );
      expect(entry.kind, ChapterDisplayKind.success);
      expect(entry.content, hasLength(1));
      expect(entry.errorMessage, isNull);
    });

    test('error factory', () {
      const entry = ChapterDisplayEntry.error(
        chapterId: 'c3',
        chapterIndex: 2,
        title: 'Chapter 3',
        errorMessage: 'Network error',
      );
      expect(entry.kind, ChapterDisplayKind.error);
      expect(entry.content, isEmpty);
      expect(entry.errorMessage, 'Network error');
    });
  });
}

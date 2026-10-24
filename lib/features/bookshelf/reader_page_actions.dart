import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import 'reader_screen_controller.dart';
import 'widgets/reader_feedback.dart';
import 'widgets/reader_sheets.dart';
import 'widgets/reader_types.dart';

class ReaderPageActions {
  ReaderPageActions({
    required this.ref,
    required this.contextOf,
    required this.screenController,
    required this.feedId,
    required this.bookId,
  });

  final WidgetRef ref;
  final BuildContext Function() contextOf;
  final ReaderScreenController screenController;
  final String feedId;
  final String bookId;

  void jumpToChapter(String chapterId, {String paragraphId = ''}) {
    screenController.jumpToChapter(chapterId, paragraphId: paragraphId);
  }

  Future<void> addBookmark(ParagraphSelection selection) async {
    final created = await screenController.addBookmark(
      chapterId: selection.chapterId,
      paragraphId: selection.paragraphId,
      paragraph: selection.paragraph,
    );
    if (!created) return;

    final context = contextOf();
    if (!context.mounted) return;
    showReaderToast(context, AppLocalizations.of(context).readerBookmarkAdded);
  }

  Future<void> openBookmarkSheet() async {
    final context = contextOf();
    await showReaderBookmarkSheet(
      context: context,
      ref: ref,
      feedId: feedId,
      bookId: bookId,
      chapters: screenController.chapters,
      onJumpToParagraph: (chapterId, paragraphId) {
        jumpToChapter(chapterId, paragraphId: paragraphId);
      },
      onBookmarkRemoved: () {
        showReaderToast(
          context,
          AppLocalizations.of(context).readerBookmarkRemoved,
        );
      },
    );
  }

  Future<void> openTocSheet() {
    return showReaderTocSheet(
      context: contextOf(),
      ref: ref,
      chapters: screenController.chapters,
      onJumpToChapter: (chapterId) {
        screenController.hideControls();
        jumpToChapter(chapterId);
      },
    );
  }

  Future<void> openInterfaceSheet() {
    return showReaderInterfaceSheet(contextOf());
  }

  Future<void> openSettingsSheet() {
    return showReaderSettingsSheet(contextOf());
  }
}

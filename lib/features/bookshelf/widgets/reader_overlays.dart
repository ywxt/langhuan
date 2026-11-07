import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../feeds/feed_service.dart';
import 'reader_bottom_bar.dart';
import 'reader_top_bar.dart';
import 'reader_types.dart';

class ReaderSelectionOverlay extends StatelessWidget {
  const ReaderSelectionOverlay({
    super.key,
    required this.selection,
    required this.theme,
    required this.l10n,
    required this.onAddBookmark,
    this.onComments,
    this.onListenFromHere,
  });

  final ParagraphSelection selection;
  final ThemeData theme;
  final AppLocalizations l10n;
  final VoidCallback onAddBookmark;
  final VoidCallback? onComments;
  final VoidCallback? onListenFromHere;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Positioned.fill(
      child: CustomSingleChildLayout(
        delegate: _SelectionToolbarLayout(selection.rect, media.padding),
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(8),
          color: theme.colorScheme.surfaceContainer,
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: onAddBookmark,
                    icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                    label: Text(
                      l10n.readerAddBookmark,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  if (onListenFromHere != null)
                    IconButton(
                      tooltip: l10n.listeningFromHere,
                      icon: const Icon(Icons.headphones, size: 18),
                      onPressed: onListenFromHere,
                    ),
                  if (onComments != null)
                    IconButton(
                      tooltip: l10n.readerParagraphComments,
                      icon: const Icon(Icons.comment_outlined, size: 18),
                      onPressed: onComments,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Positions the toolbar using its actual size after wrapping or text scaling.
class _SelectionToolbarLayout extends SingleChildLayoutDelegate {
  _SelectionToolbarLayout(this.selection, this.safeArea);

  final Rect selection;
  final EdgeInsets safeArea;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: (constraints.maxWidth - 32).clamp(0, double.infinity),
        maxHeight: (constraints.maxHeight - safeArea.vertical - 8).clamp(
          0,
          double.infinity,
        ),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final minTop = safeArea.top + 4;
    final maxTop = (size.height - safeArea.bottom - childSize.height - 4).clamp(
      minTop,
      double.infinity,
    );
    final above = selection.top - childSize.height - 8;
    final preferred = above < minTop ? selection.bottom + 8 : above;
    return Offset(
      (size.width - childSize.width) / 2,
      preferred.clamp(minTop, maxTop),
    );
  }

  @override
  bool shouldRelayout(_SelectionToolbarLayout oldDelegate) =>
      oldDelegate.selection != selection || oldDelegate.safeArea != safeArea;
}

class ReaderTopOverlay extends StatelessWidget {
  const ReaderTopOverlay({
    super.key,
    required this.showControls,
    required this.theme,
    required this.topPadding,
    required this.chapterTitle,
    required this.l10n,
    required this.isRefreshing,
    required this.onBack,
    required this.onOpenBookmarks,
    required this.onRefresh,
    this.additionalActions = const [],
  });

  final bool showControls;
  final ThemeData theme;
  final double topPadding;
  final String chapterTitle;
  final AppLocalizations l10n;
  final bool isRefreshing;
  final VoidCallback onBack;
  final VoidCallback onOpenBookmarks;
  final VoidCallback onRefresh;
  final List<Widget> additionalActions;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        ignoring: !showControls,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 180),
          offset: showControls ? Offset.zero : const Offset(0, -1),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 180),
            opacity: showControls ? 1 : 0,
            child: ReaderTopBar(
              topPadding: topPadding,
              chapterTitle: chapterTitle,
              backgroundColor: theme.colorScheme.surfaceContainer,
              titleTextStyle: theme.textTheme.titleMedium,
              bookmarksTooltip: l10n.readerBookmarks,
              refreshTooltip: l10n.readerRefreshChapter,
              isRefreshing: isRefreshing,
              onBack: onBack,
              onOpenBookmarks: onOpenBookmarks,
              onRefresh: onRefresh,
              additionalActions: additionalActions,
            ),
          ),
        ),
      ),
    );
  }
}

class ReaderBottomOverlay extends StatelessWidget {
  const ReaderBottomOverlay({
    super.key,
    required this.showControls,
    required this.chapters,
    required this.currentIndex,
    required this.isSwitchingChapter,
    required this.onPrevious,
    required this.onNext,
    required this.onOpenToc,
    required this.onOpenInterface,
    required this.onOpenSettings,
  });

  final bool showControls;
  final List<ChapterInfoModel> chapters;
  final int currentIndex;
  final bool isSwitchingChapter;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onOpenToc;
  final VoidCallback onOpenInterface;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        ignoring: !showControls,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 180),
          offset: showControls ? Offset.zero : const Offset(0, 1),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 180),
            opacity: showControls ? 1 : 0,
            child: ReaderBottomBar(
              chapters: chapters,
              currentIndex: currentIndex,
              isSwitchingChapter: isSwitchingChapter,
              onPrevious: onPrevious,
              onNext: onNext,
              onOpenToc: onOpenToc,
              onOpenInterface: onOpenInterface,
              onOpenSettings: onOpenSettings,
            ),
          ),
        ),
      ),
    );
  }
}

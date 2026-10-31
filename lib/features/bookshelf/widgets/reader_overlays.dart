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
  });

  final ParagraphSelection selection;
  final ThemeData theme;
  final AppLocalizations l10n;
  final VoidCallback onAddBookmark;
  final VoidCallback? onComments;

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;

    const toolbarHeight = 40.0;
    const toolbarPadding = 8.0;
    final top = selection.rect.top - toolbarHeight - toolbarPadding;
    final safeTop = top < MediaQuery.of(context).padding.top + 4
        ? selection.rect.bottom + toolbarPadding
        : top;

    return Positioned(
      top: safeTop,
      left: 0,
      right: 0,
      child: Center(
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(8),
          color: theme.colorScheme.surfaceContainer,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: screenWidth * 0.7),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onAddBookmark,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.bookmark_add_outlined, size: 18),
                    const SizedBox(width: 4),
                    Text(
                      l10n.readerAddBookmark,
                      style: const TextStyle(fontSize: 13),
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
      ),
    );
  }
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

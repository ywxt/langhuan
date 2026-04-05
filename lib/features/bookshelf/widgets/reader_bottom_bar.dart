import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../feeds/feed_service.dart';

/// Bottom bar shown in the reader when the user taps the screen.
///
/// Displays chapter progress and prev/next navigation buttons.
class ReaderBottomBar extends StatelessWidget {
  const ReaderBottomBar({
    super.key,
    required this.chapters,
    required this.currentIndex,
    required this.isSwitchingChapter,
    required this.onPrevious,
    required this.onNext,
  });

  final List<ChapterInfoModel> chapters;
  final int currentIndex;
  final bool isSwitchingChapter;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final canGoPrev = currentIndex > 0;
    final canGoNext = currentIndex >= 0 && currentIndex < chapters.length - 1;
    final chapterProgress = chapters.isEmpty
        ? 0.0
        : ((currentIndex < 0 ? 0 : currentIndex + 1) / chapters.length).clamp(
            0.0,
            1.0,
          );

    return SafeArea(
      top: false,
      child: Container(
        color: Theme.of(context).colorScheme.surfaceContainer,
        padding: const EdgeInsets.fromLTRB(
          LanghuanTheme.spaceMd,
          LanghuanTheme.spaceSm,
          LanghuanTheme.spaceMd,
          LanghuanTheme.spaceMd,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (chapters.isNotEmpty) ...[
              Text(
                l10n.readerChapterProgress(
                  currentIndex < 0 ? 0 : currentIndex + 1,
                  chapters.length,
                ),
                style: Theme.of(context).textTheme.labelMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: LanghuanTheme.spaceXs),
              LinearProgressIndicator(value: chapterProgress),
              const SizedBox(height: LanghuanTheme.spaceSm),
            ],
            Row(
              children: [
                Expanded(
                  child: TextButton.icon(
                    onPressed:
                        (chapters.isEmpty || !canGoPrev || isSwitchingChapter)
                        ? null
                        : onPrevious,
                    icon: const Icon(Icons.chevron_left),
                    label: Text(l10n.readerPrevChapter),
                  ),
                ),
                const SizedBox(width: LanghuanTheme.spaceSm),
                Expanded(
                  child: TextButton.icon(
                    onPressed:
                        (chapters.isEmpty || !canGoNext || isSwitchingChapter)
                        ? null
                        : onNext,
                    iconAlignment: IconAlignment.end,
                    icon: const Icon(Icons.chevron_right),
                    label: Text(l10n.readerNextChapter),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

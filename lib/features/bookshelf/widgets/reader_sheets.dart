import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/utils/snackbars.dart';
import '../../feeds/feed_service.dart';
import '../bookmark_provider.dart';
import '../reader_settings_provider.dart';
import '../reading_progress_provider.dart';
import 'chinese_conversion_picker.dart';

Future<void> showReaderInterfaceSheet(BuildContext context) async {
  final l10n = AppLocalizations.of(context);

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => Consumer(
      builder: (context, ref, _) {
        final settings = ref.watch(readerSettingsProvider);
        final notifier = ref.read(readerSettingsProvider.notifier);

        return StatefulBuilder(
          builder: (context, setModalState) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(LanghuanTheme.spaceLg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l10n.readerInterface,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: LanghuanTheme.spaceMd),
                  Row(
                    children: [
                      Icon(
                        Icons.auto_stories_outlined,
                        size: 18,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: LanghuanTheme.spaceSm),
                      Text(
                        l10n.readerModeLabel,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: LanghuanTheme.spaceSm),
                  SegmentedButton<ReaderPageMode>(
                    segments: [
                      ButtonSegment(
                        value: ReaderPageMode.horizontal,
                        icon: const Icon(Icons.swap_horiz, size: 18),
                        label: Text(l10n.readerModeHorizontal),
                      ),
                      ButtonSegment(
                        value: ReaderPageMode.vertical,
                        icon: const Icon(Icons.swap_vert, size: 18),
                        label: Text(l10n.readerModeVertical),
                      ),
                    ],
                    selected: {settings.pageMode},
                    onSelectionChanged: (selection) {
                      setModalState(() {});
                      notifier.setPageMode(selection.first);
                    },
                  ),
                  const SizedBox(height: LanghuanTheme.spaceMd),
                  Text(l10n.readerFontFileLabel),
                  const SizedBox(height: LanghuanTheme.spaceSm),
                  Text(
                    settings.customFontDisplayName ?? l10n.readerFontSystemDefault,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: LanghuanTheme.spaceSm),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () async {
                            final result = await FilePicker.pickFiles(
                              type: FileType.custom,
                              allowedExtensions: const ['ttf', 'otf'],
                            );
                            if (result.isEmpty) return;
                            final path = result.single.path;
                            if (path == null || path.isEmpty) return;

                            try {
                              await notifier.loadFontFromFile(path);
                              if (context.mounted) {
                                setModalState(() {});
                              }
                            } catch (_) {
                              if (!context.mounted) return;
                              showErrorSnack(
                                ScaffoldMessenger.of(context),
                                l10n.readerFontLoadFailed,
                              );
                            }
                          },
                          icon: const Icon(Icons.upload_file),
                          label: Text(l10n.readerFontChoose),
                        ),
                      ),
                      const SizedBox(width: LanghuanTheme.spaceSm),
                      OutlinedButton(
                        onPressed: () {
                          notifier.clearCustomFont();
                          setModalState(() {});
                        },
                        child: Text(l10n.readerFontReset),
                      ),
                    ],
                  ),
                  const SizedBox(height: LanghuanTheme.spaceMd),
                  Text(l10n.readerFontScale(settings.fontScale.toStringAsFixed(2))),
                  Slider(
                    value: settings.fontScale,
                    min: 0.8,
                    max: 1.8,
                    divisions: 10,
                    onChanged: (v) {
                      notifier.setFontScale(v);
                      setModalState(() {});
                    },
                  ),
                  const SizedBox(height: LanghuanTheme.spaceSm),
                  Text(
                    l10n.readerLetterSpacing(
                      settings.letterSpacing.toStringAsFixed(2),
                    ),
                  ),
                  Slider(
                    value: settings.letterSpacing,
                    min: 0,
                    max: 4,
                    divisions: 16,
                    onChanged: (v) {
                      notifier.setLetterSpacing(v);
                      setModalState(() {});
                    },
                  ),
                  const SizedBox(height: LanghuanTheme.spaceSm),
                  Text(
                    l10n.readerParagraphSpacing(
                      settings.paragraphSpacing.toStringAsFixed(0),
                    ),
                  ),
                  Slider(
                    value: settings.paragraphSpacing,
                    min: 4,
                    max: 32,
                    divisions: 14,
                    onChanged: (v) {
                      notifier.setParagraphSpacing(v);
                      setModalState(() {});
                    },
                  ),
                  const SizedBox(height: LanghuanTheme.spaceSm),
                  Text(
                    l10n.readerLineHeight(
                      settings.lineHeight.toStringAsFixed(2),
                    ),
                  ),
                  Slider(
                    value: settings.lineHeight,
                    min: 1.2,
                    max: 2.4,
                    divisions: 12,
                    onChanged: (v) {
                      notifier.setLineHeight(v);
                      setModalState(() {});
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    ),
  );
}

Future<void> showReaderSettingsSheet(BuildContext context) async {
  final l10n = AppLocalizations.of(context);

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => Consumer(
      builder: (context, ref, _) {
        final settings = ref.watch(readerSettingsProvider);
        final notifier = ref.read(readerSettingsProvider.notifier);

        return SingleChildScrollView(
          padding: const EdgeInsets.all(LanghuanTheme.spaceLg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.readerSettings,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: LanghuanTheme.spaceMd),
              Text(
                l10n.readerChineseConversion,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: LanghuanTheme.spaceSm),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.translate),
                  label: Text(
                    chineseConversionLabel(l10n, settings.chineseConversion),
                  ),
                  onPressed: () async {
                    final mode = await showChineseConversionPicker(
                      context,
                      selected: settings.chineseConversion,
                    );
                    if (mode != null) notifier.setChineseConversion(mode);
                  },
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

Future<void> showReaderBookmarkSheet({
  required BuildContext context,
  required WidgetRef ref,
  required String feedId,
  required String bookId,
  required List<ChapterInfoModel> chapters,
  required void Function(String chapterId, String paragraphId)
  onJumpToParagraph,
  required VoidCallback onBookmarkRemoved,
}) async {
  final l10n = AppLocalizations.of(context);
  await ref
      .read(bookmarkProvider.notifier)
      .load(feedId: feedId, bookId: bookId);
  if (!context.mounted) return;

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => Consumer(
      builder: (context, ref, _) {
        final bookmarks = ref.watch(bookmarkProvider).items;
        if (bookmarks.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(LanghuanTheme.spaceLg),
            child: Center(child: Text(l10n.readerNoBookmarks)),
          );
        }

        return ListView.builder(
          itemCount: bookmarks.length,
          itemBuilder: (context, index) {
            final item = bookmarks[index];
            final chapterIndex = chapters.indexWhere(
              (c) => c.id == item.chapterId,
            );
            final chapterTitle = chapterIndex >= 0
                ? chapters[chapterIndex].title
                : item.chapterId;
            return ListTile(
              title: Text(chapterTitle),
              subtitle: Text(
                item.paragraphName.trim().isEmpty
                    ? item.paragraphId
                    : item.paragraphName,
              ),
              onTap: () {
                Navigator.of(context).pop();
                onJumpToParagraph(item.chapterId, item.paragraphId);
              },
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  await ref.read(bookmarkProvider.notifier).remove(item.id);
                  if (!context.mounted) return;
                  onBookmarkRemoved();
                },
              ),
            );
          },
        );
      },
    ),
  );
}

Future<void> showReaderTocSheet({
  required BuildContext context,
  required WidgetRef ref,
  required List<ChapterInfoModel> chapters,
  required void Function(String chapterId) onJumpToChapter,
}) async {
  final reading = ref.read(readingProgressProvider);
  final activeId = reading.activeChapterId;
  final activeIdx = chapters.indexWhere((c) => c.id == activeId);
  final scrollController = ScrollController(
    initialScrollOffset: activeIdx > 0 ? activeIdx * 56.0 : 0,
  );

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => Consumer(
      builder: (context, ref, _) {
        final reading = ref.watch(readingProgressProvider);
        final currentActiveId = reading.activeChapterId;
        return ListView.builder(
          controller: scrollController,
          itemCount: chapters.length,
          itemExtent: 56.0,
          itemBuilder: (context, index) {
            final chapter = chapters[index];
            final isActive = chapter.id == currentActiveId;
            return ListTile(
              leading: Text('${index + 1}'),
              title: Text(
                chapter.title,
                style: isActive
                    ? TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      )
                    : null,
              ),
              selected: isActive,
              onTap: () {
                Navigator.of(context).pop();
                onJumpToChapter(chapter.id);
              },
            );
          },
        );
      },
    ),
  );

  scrollController.dispose();
}

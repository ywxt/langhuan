import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/utils/snackbars.dart';
import '../../../shared/widgets/chapter_scrollbar.dart';
import '../../../shared/widgets/setting_value_row.dart';
import '../../feeds/feed_service.dart';
import '../../transformers/transformer_settings_page.dart';
import '../bookmark_provider.dart';
import '../reader_settings_provider.dart';
import '../reading_progress_provider.dart';
import 'reader_theme_picker.dart';

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
                  Text(
                    l10n.readerModeLabel,
                    key: const ValueKey('reader-mode-title'),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: LanghuanTheme.spaceSm),
                  SegmentedButton<ReaderPageMode>(
                    key: const ValueKey('reader-mode-control'),
                    expandedInsets: EdgeInsets.zero,
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
                  SettingValueRow(
                    label: l10n.readerFontFileLabel,
                    value:
                        settings.customFontDisplayName ??
                        l10n.readerFontSystemDefault,
                  ),
                  const SizedBox(height: LanghuanTheme.spaceSm),
                  Row(
                    key: const ValueKey('reader-font-actions'),
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
                  // Each commit re-paginates the loaded window (a few
                  // milliseconds of layout per frame until it settles), so
                  // the sliders commit throttled live values while dragging
                  // — the reader reflows in place as a preview — and commit
                  // the exact value when the drag ends.
                  _TypoSlider(
                    label: l10n.readerFontScale,
                    valueBuilder: (v) => '${v.toStringAsFixed(2)}x',
                    value: settings.fontScale,
                    min: ReaderSettingsState.minFontScale,
                    max: ReaderSettingsState.maxFontScale,
                    divisions: 25,
                    onCommit: notifier.setFontScale,
                  ),
                  const SizedBox(height: LanghuanTheme.spaceSm),
                  _TypoSlider(
                    label: l10n.readerLetterSpacing,
                    valueBuilder: (v) => v.toStringAsFixed(2),
                    value: settings.letterSpacing,
                    min: 0,
                    max: 4,
                    divisions: 16,
                    onCommit: notifier.setLetterSpacing,
                  ),
                  const SizedBox(height: LanghuanTheme.spaceSm),
                  _TypoSlider(
                    label: l10n.readerParagraphSpacing,
                    valueBuilder: (v) => v.toStringAsFixed(0),
                    value: settings.paragraphSpacing,
                    min: 4,
                    max: 32,
                    divisions: 14,
                    onCommit: notifier.setParagraphSpacing,
                  ),
                  const SizedBox(height: LanghuanTheme.spaceSm),
                  _TypoSlider(
                    label: l10n.readerLineHeight,
                    valueBuilder: (v) => v.toStringAsFixed(2),
                    value: settings.lineHeight,
                    min: 1.2,
                    max: 2.4,
                    divisions: 12,
                    onCommit: notifier.setLineHeight,
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

/// A typography slider that commits throttled live values mid-drag.
///
/// Committing a typography change re-paginates the loaded chapter window,
/// but that work is spread across frame-budgeted slices (about 4 ms per
/// frame; a window chapter needs a handful of them), so a drag can commit
/// as it goes: the first tick lands immediately, further ticks are
/// rate-limited to one commit per [_liveCommitInterval], and a trailing
/// timer picks up the latest value. Releasing the slider cancels any
/// pending timer and commits the exact final value.
class _TypoSlider extends StatefulWidget {
  const _TypoSlider({
    required this.label,
    required this.valueBuilder,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    required this.onCommit,
  });

  final String label;
  final String Function(double value) valueBuilder;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onCommit;

  @override
  State<_TypoSlider> createState() => _TypoSliderState();
}

class _TypoSliderState extends State<_TypoSlider> {
  /// Minimum spacing between live commits during a drag. A reflowed
  /// window chapter paginates for roughly this long (measured 12–35 ms of
  /// work spread over 3–9 frames on realistic chapters), so commits at
  /// this rate let pagination settle between them.
  static const _liveCommitInterval = Duration(milliseconds: 250);

  double? _dragValue;
  Timer? _liveCommitTimer;
  DateTime? _lastLiveCommitAt;

  @override
  void dispose() {
    _liveCommitTimer?.cancel();
    super.dispose();
  }

  void _onChanged(double value) {
    setState(() => _dragValue = value);
    final now = DateTime.now();
    final last = _lastLiveCommitAt;
    if (last == null || now.difference(last) >= _liveCommitInterval) {
      _commitLive(value, at: now);
      return;
    }
    // Rate-limited: schedule the trailing commit for the latest value so
    // continuous drags still land every change within one interval.
    _liveCommitTimer?.cancel();
    _liveCommitTimer = Timer(_liveCommitInterval - now.difference(last), () {
      _liveCommitTimer = null;
      if (!mounted) return;
      final latest = _dragValue;
      if (latest == null) return;
      _commitLive(latest, at: DateTime.now());
    });
  }

  void _onChangeEnd(double value) {
    _liveCommitTimer?.cancel();
    _liveCommitTimer = null;
    _lastLiveCommitAt = null;
    setState(() => _dragValue = null);
    widget.onCommit(value);
  }

  void _commitLive(double value, {required DateTime at}) {
    _lastLiveCommitAt = at;
    widget.onCommit(value);
  }

  @override
  Widget build(BuildContext context) {
    final current = _dragValue ?? widget.value;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingValueRow(
          label: widget.label,
          value: widget.valueBuilder(current),
        ),
        Slider(
          value: current.clamp(widget.min, widget.max),
          min: widget.min,
          max: widget.max,
          divisions: widget.divisions,
          onChanged: _onChanged,
          onChangeEnd: _onChangeEnd,
        ),
      ],
    );
  }
}

Future<void> showReaderSettingsSheet(
  BuildContext context, {
  String? feedId,
  String? bookId,
}) async {
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
                l10n.readerThemeLabel,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: LanghuanTheme.spaceSm),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.palette_outlined),
                      label: Text(
                        readerThemeModeLabel(l10n, settings.themeMode),
                      ),
                      onPressed: () async {
                        final mode = await showReaderThemePicker(
                          context,
                          selected: settings.themeMode,
                          customTheme: settings.customTheme,
                        );
                        if (mode == null || !context.mounted) return;
                        if (mode != ReaderThemeMode.custom) {
                          notifier.setThemeMode(mode);
                          return;
                        }
                        final customTheme = await showReaderCustomThemeEditor(
                          context,
                          initial: settings.customTheme,
                        );
                        if (customTheme != null) {
                          notifier.setCustomTheme(customTheme);
                        }
                      },
                    ),
                  ),
                  if (settings.themeMode == ReaderThemeMode.custom) ...[
                    const SizedBox(width: LanghuanTheme.spaceSm),
                    IconButton.filledTonal(
                      tooltip: l10n.readerThemeCustomizeTitle,
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () async {
                        final customTheme = await showReaderCustomThemeEditor(
                          context,
                          initial: settings.customTheme,
                        );
                        if (customTheme != null) {
                          notifier.setCustomTheme(customTheme);
                        }
                      },
                    ),
                  ],
                ],
              ),
              const SizedBox(height: LanghuanTheme.spaceMd),
              Text(
                l10n.transformTitle,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: LanghuanTheme.spaceSm),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.translate),
                  label: Text(l10n.transformBookSettings),
                  onPressed: () async {
                    await openTransformerSettings(
                      context,
                      feedId: feedId,
                      bookId: bookId,
                    );
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
    isScrollControlled: true,
    builder: (context) => _FilterableSheet(
      hintText: l10n.readerSearchBookmarksHint,
      child: Consumer(
        builder: (context, ref, _) {
          final bookmarks = ref.watch(bookmarkProvider).items;
          if (bookmarks.isEmpty) {
            return _SheetMessage(message: l10n.readerNoBookmarks);
          }

          return Builder(
            builder: (context) {
              final query = _FilterableSheet.queryOf(context);
              final filtered = _filterBookmarks(bookmarks, chapters, query);
              if (filtered.isEmpty) {
                return _SheetMessage(message: l10n.readerSearchNoMatch(query));
              }

              return ListView.builder(
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final item = filtered[index];
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
                        await ref
                            .read(bookmarkProvider.notifier)
                            .remove(item.id);
                        if (!context.mounted) return;
                        onBookmarkRemoved();
                      },
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    ),
  );
}

/// Bookmarks whose chapter title, paragraph name or preview matches
/// [query] (case-insensitive; empty query keeps everything).
List<BookmarkModel> _filterBookmarks(
  List<BookmarkModel> bookmarks,
  List<ChapterInfoModel> chapters,
  String query,
) {
  if (query.isEmpty) return bookmarks;
  return bookmarks.where((item) {
    final chapterIndex = chapters.indexWhere((c) => c.id == item.chapterId);
    final haystack = [
      chapterIndex >= 0 ? chapters[chapterIndex].title : item.chapterId,
      item.paragraphName,
      item.paragraphPreview,
      item.paragraphId,
    ].join('\n').toLowerCase();
    return haystack.contains(query);
  }).toList();
}

Future<void> showReaderTocSheet({
  required BuildContext context,
  required WidgetRef ref,
  required List<ChapterInfoModel> chapters,
  required void Function(String chapterId) onJumpToChapter,
}) async {
  final l10n = AppLocalizations.of(context);
  final reading = ref.read(readingProgressProvider);
  final activeId = reading.activeChapterId;
  final activeIdx = chapters.indexWhere((c) => c.id == activeId);
  final scrollController = ScrollController(
    initialScrollOffset: activeIdx > 0 ? activeIdx * 72.0 : 0,
  );

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => _FilterableSheet(
      hintText: l10n.readerSearchTocHint,
      child: Consumer(
        builder: (context, ref, _) {
          final reading = ref.watch(readingProgressProvider);
          final currentActiveId = reading.activeChapterId;

          return Builder(
            builder: (context) {
              final query = _FilterableSheet.queryOf(context);
              final filtered = _filterChapters(chapters, query);

              if (filtered.isEmpty) {
                return _SheetMessage(message: l10n.readerSearchNoMatch(query));
              }

              return ChapterScrollbar(
                controller: scrollController,
                child: ListView.builder(
                  controller: scrollController,
                  itemCount: filtered.length,
                  itemExtent: 72.0,
                  itemBuilder: (context, index) {
                    final (chapterNo, chapter) = filtered[index];
                    final isActive = chapter.id == currentActiveId;
                    return ListTile(
                      leading: Text('$chapterNo'),
                      title: Text(
                        chapter.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
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
                ),
              );
            },
          );
        },
      ),
    ),
  );

  scrollController.dispose();
}

/// Chapters whose title matches [query], paired with their original
/// one-based number so filtered lists keep the book's real numbering.
List<(int, ChapterInfoModel)> _filterChapters(
  List<ChapterInfoModel> chapters,
  String query,
) {
  final numbered = [
    for (var i = 0; i < chapters.length; i++) (i + 1, chapters[i]),
  ];
  if (query.isEmpty) return numbered;
  return numbered
      .where((entry) => entry.$2.title.toLowerCase().contains(query))
      .toList();
}

/// Sheet scaffold: a pinned search bar over a scrolling body, sized to most
/// of the screen and inset for the on-screen keyboard.
///
/// Descendants read the normalized query through [queryOf], which rebuilds
/// them on every keystroke via the inherited widget.
class _FilterableSheet extends StatefulWidget {
  const _FilterableSheet({required this.hintText, required this.child});

  final String hintText;
  final Widget child;

  static String queryOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_FilterableSheetScope>();
    return scope?.query ?? '';
  }

  @override
  State<_FilterableSheet> createState() => _FilterableSheetState();
}

class _FilterableSheetScope extends InheritedWidget {
  const _FilterableSheetScope({required this.query, required super.child});

  final String query;

  @override
  bool updateShouldNotify(_FilterableSheetScope oldWidget) =>
      query != oldWidget.query;
}

class _FilterableSheetState extends State<_FilterableSheet> {
  final TextEditingController _filterController = TextEditingController();

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.8,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                LanghuanTheme.spaceLg,
                LanghuanTheme.spaceSm,
                LanghuanTheme.spaceLg,
                LanghuanTheme.spaceSm,
              ),
              child: SearchBar(
                controller: _filterController,
                autoFocus: false,
                hintText: widget.hintText,
                leading: Icon(
                  Icons.search,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                trailing: [
                  if (_filterController.text.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _filterController.clear();
                        setState(() {});
                      },
                    ),
                ],
                onChanged: (_) => setState(() {}),
              ),
            ),
            Expanded(
              child: _FilterableSheetScope(
                query: _filterController.text.trim().toLowerCase(),
                child: widget.child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetMessage extends StatelessWidget {
  const _SheetMessage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(LanghuanTheme.spaceLg),
      child: Center(child: Text(message)),
    );
  }
}

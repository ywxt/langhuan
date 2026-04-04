import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/error_state.dart';
import '../../src/bindings/signals/signals.dart';
import '../feeds/feed_providers.dart';
import '../feeds/feed_service.dart';

class ReaderPage extends ConsumerStatefulWidget {
  const ReaderPage({
    super.key,
    required this.feedId,
    required this.bookId,
    required this.chapterId,
  });

  final String feedId;
  final String bookId;
  final String chapterId;

  @override
  ConsumerState<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends ConsumerState<ReaderPage> {
  static const double _swipeVelocityThreshold = 220;
  String? _currentChapterId;
  bool _isSwitchingChapter = false;

  @override
  void initState() {
    super.initState();
    _currentChapterId = widget.chapterId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ensureLoaded();
    });
  }

  Future<void> _ensureLoaded() async {
    if (widget.feedId.isEmpty ||
        widget.bookId.isEmpty ||
        widget.chapterId.isEmpty) {
      return;
    }

    final chaptersState = ref.read(chaptersProvider);
    if (chaptersState.bookId != widget.bookId || chaptersState.items.isEmpty) {
      await ref
          .read(chaptersProvider.notifier)
          .load(feedId: widget.feedId, bookId: widget.bookId);
    }

    final chapterId = _currentChapterId;
    if (chapterId == null || chapterId.isEmpty) {
      return;
    }

    await ref
        .read(chapterContentProvider.notifier)
        .load(feedId: widget.feedId, chapterId: chapterId);
  }

  int _currentChapterIndex(List<ChapterInfoModel> chapters) {
    final chapterId = _currentChapterId;
    if (chapterId == null) return -1;
    return chapters.indexWhere((c) => c.id == chapterId);
  }

  Future<void> _jumpToChapter(
    BuildContext context,
    List<ChapterInfoModel> chapters,
    int targetIndex,
  ) async {
    if (_isSwitchingChapter) return;

    final l10n = AppLocalizations.of(context);
    if (targetIndex < 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.readerAtFirstChapter)));
      return;
    }
    if (targetIndex >= chapters.length) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.readerAtLastChapter)));
      return;
    }

    final contentState = ref.read(chapterContentProvider);
    if (contentState.isLoading) {
      return;
    }

    final target = chapters[targetIndex];
    _isSwitchingChapter = true;
    setState(() {
      _currentChapterId = target.id;
    });
    try {
      await ref
          .read(chapterContentProvider.notifier)
          .load(feedId: widget.feedId, chapterId: target.id);
    } finally {
      _isSwitchingChapter = false;
    }
  }

  Future<void> _onHorizontalDragEnd(
    BuildContext context,
    DragEndDetails details,
    List<ChapterInfoModel> chapters,
  ) async {
    final v = details.primaryVelocity ?? 0;
    if (v.abs() < _swipeVelocityThreshold) return;

    final idx = _currentChapterIndex(chapters);
    if (idx < 0) return;

    if (v < 0) {
      await _jumpToChapter(context, chapters, idx + 1);
    } else {
      await _jumpToChapter(context, chapters, idx - 1);
    }
  }

  List<Widget> _buildParagraphs(
    BuildContext context,
    List<ParagraphContent> items,
  ) {
    final theme = Theme.of(context);
    final widgets = <Widget>[];

    for (final item in items) {
      if (item is ParagraphContentTitle) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(bottom: LanghuanTheme.spaceMd),
            child: Text(
              item.text,
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
          ),
        );
        continue;
      }

      if (item is ParagraphContentText) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(bottom: LanghuanTheme.spaceMd),
            child: Text(
              item.content,
              style: theme.textTheme.bodyLarge?.copyWith(height: 1.8),
            ),
          ),
        );
        continue;
      }

      if (item is ParagraphContentImage) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(bottom: LanghuanTheme.spaceLg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ClipRRect(
                  borderRadius: LanghuanTheme.borderRadiusMd,
                  child: Image.network(
                    item.url,
                    fit: BoxFit.cover,
                    loadingBuilder: (context, child, progress) {
                      if (progress == null) return child;
                      return const AspectRatio(
                        aspectRatio: 16 / 9,
                        child: Center(child: CircularProgressIndicator()),
                      );
                    },
                    errorBuilder: (_, _, _) => const AspectRatio(
                      aspectRatio: 16 / 9,
                      child: Center(child: Icon(Icons.broken_image_outlined)),
                    ),
                  ),
                ),
                if (item.alt != null && item.alt!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: LanghuanTheme.spaceSm),
                    child: Text(
                      item.alt!,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
              ],
            ),
          ),
        );
      }
    }

    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final chaptersState = ref.watch(chaptersProvider);
    final contentState = ref.watch(chapterContentProvider);

    if (widget.feedId.isEmpty ||
        widget.bookId.isEmpty ||
        widget.chapterId.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.readerTitle)),
        body: EmptyState(
          icon: Icons.info_outline,
          title: l10n.readerMissingParams,
        ),
      );
    }

    final chapters = chaptersState.items;
    final currentIdx = _currentChapterIndex(chapters);
    final canGoPrev = currentIdx > 0;
    final canGoNext = currentIdx >= 0 && currentIdx < chapters.length - 1;
    final chapterTitle = currentIdx >= 0
        ? chapters[currentIdx].title
        : l10n.readerTitle;

    Widget body;
    if (contentState.isLoading && contentState.items.isEmpty) {
      body = const Center(child: CircularProgressIndicator());
    } else if (contentState.hasError && contentState.items.isEmpty) {
      body = ErrorState(
        title: l10n.readerLoadError,
        message: contentState.error.toString(),
        onRetry: () => ref
            .read(chapterContentProvider.notifier)
            .retry(feedId: widget.feedId),
        retryLabel: l10n.bookDetailRetry,
      );
    } else if (contentState.items.isEmpty) {
      body = EmptyState(
        icon: Icons.menu_book_outlined,
        title: l10n.readerEmpty,
      );
    } else {
      final paragraphWidgets = _buildParagraphs(context, contentState.items);
      body = ListView.builder(
        padding: const EdgeInsets.fromLTRB(
          LanghuanTheme.spaceLg,
          LanghuanTheme.spaceLg,
          LanghuanTheme.spaceLg,
          LanghuanTheme.space2xl,
        ),
        itemCount: paragraphWidgets.length,
        itemBuilder: (context, index) => paragraphWidgets[index],
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(chapterTitle)),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragEnd: (d) => _onHorizontalDragEnd(context, d, chapters),
        child: Column(
          children: [
            if (chapters.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: LanghuanTheme.spaceLg,
                  vertical: LanghuanTheme.spaceSm,
                ),
                child: Text(
                  l10n.readerChapterProgress(
                    currentIdx < 0 ? 0 : currentIdx + 1,
                    chapters.length,
                  ),
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
            Expanded(child: body),
            SafeArea(
              top: false,
              child: Container(
                color: Theme.of(context).colorScheme.surfaceContainer,
                padding: const EdgeInsets.symmetric(
                  horizontal: LanghuanTheme.spaceMd,
                  vertical: LanghuanTheme.spaceSm,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextButton.icon(
                        onPressed:
                            (chapters.isEmpty ||
                                !canGoPrev ||
                                _isSwitchingChapter)
                            ? null
                            : () => _jumpToChapter(
                                context,
                                chapters,
                                currentIdx - 1,
                              ),
                        icon: const Icon(Icons.chevron_left),
                        label: Text(l10n.readerPrevChapter),
                      ),
                    ),
                    const SizedBox(width: LanghuanTheme.spaceSm),
                    Expanded(
                      child: TextButton.icon(
                        onPressed:
                            (chapters.isEmpty ||
                                !canGoNext ||
                                _isSwitchingChapter)
                            ? null
                            : () => _jumpToChapter(
                                context,
                                chapters,
                                currentIdx + 1,
                              ),
                        iconAlignment: IconAlignment.end,
                        icon: const Icon(Icons.chevron_right),
                        label: Text(l10n.readerNextChapter),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

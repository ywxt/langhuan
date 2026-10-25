import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/app_localizations.dart';
import '../../rust_init.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/utils/snackbars.dart';
import '../../shared/widgets/confirm_dialog.dart';
import '../../shared/widgets/cover_image.dart';
import '../../shared/widgets/cover_placeholder.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/error_state.dart';
import '../../shared/widgets/loading.dart';
import 'book_providers.dart';
import 'bookshelf_provider.dart';
import 'reading_progress_provider.dart';
import 'widgets/book_cover.dart';
import 'widgets/book_cover_hero.dart';
import 'widgets/reader_types.dart';

class BookDetailRouteExtra {
  const BookDetailRouteExtra({this.coverUrl, this.title, this.author});

  final String? coverUrl;
  final String? title;
  final String? author;
}

class BookDetailPage extends ConsumerStatefulWidget {
  const BookDetailPage({
    super.key,
    required this.feedId,
    required this.bookId,
    this.initialBook,
  });

  final String feedId;
  final String bookId;
  final BookDetailRouteExtra? initialBook;

  @override
  ConsumerState<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends ConsumerState<BookDetailPage> {
  late final BookInfoNotifier _bookInfoNotifier;
  late final ChaptersNotifier _chaptersNotifier;
  late final ReadingProgressNotifier _progressNotifier;

  void _openReader(BuildContext context, String chapterId) {
    context.pushNamed(
      'bookshelf-reader',
      queryParameters: {
        'feedId': widget.feedId,
        'bookId': widget.bookId,
        'chapterId': chapterId,
        'paragraphId': '',
      },
    );
  }

  @override
  void initState() {
    super.initState();
    // Cache notifiers while widget is mounted to safely use them in async operations.
    // This prevents "Using ref when widget is unmounted" errors.
    _bookInfoNotifier = ref.read(bookInfoProvider.notifier);
    _chaptersNotifier = ref.read(chaptersProvider.notifier);
    _progressNotifier = ref.read(readingProgressProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadAfterEntranceTransition();
    });
  }

  Future<void> _loadAfterEntranceTransition() async {
    if (!mounted) return;
    final animation = ModalRoute.of(context)?.animation;
    if (animation != null && animation.status != AnimationStatus.completed) {
      final completer = Completer<void>();

      void onStatus(AnimationStatus status) {
        if ((status == AnimationStatus.completed ||
                status == AnimationStatus.dismissed) &&
            !completer.isCompleted) {
          completer.complete();
        }
      }

      animation.addStatusListener(onStatus);
      if (animation.status == AnimationStatus.completed ||
          animation.status == AnimationStatus.dismissed) {
        completer.complete();
      }
      await completer.future;
      animation.removeStatusListener(onStatus);
    }
    if (mounted) await _load();
  }

  Future<void> _load() async {
    if (widget.feedId.isEmpty || widget.bookId.isEmpty) return;

    await _bookInfoNotifier.load(feedId: widget.feedId, bookId: widget.bookId);
    if (!mounted) return;
    await _chaptersNotifier.load(feedId: widget.feedId, bookId: widget.bookId);
    if (!mounted) return;
    final chapters = ref.read(chaptersProvider).items;
    final fallbackChapterId = chapters.isEmpty ? '' : chapters.first.id;
    await _progressNotifier.load(
      feedId: widget.feedId,
      bookId: widget.bookId,
      fallbackChapterId: fallbackChapterId,
      fallbackParagraphId: '',
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final bookInfoState = ref.watch(bookInfoProvider);
    final chaptersState = ref.watch(chaptersProvider);
    final progressState = ref.watch(readingProgressProvider);
    final bootstrap = ref.watch(appDataDirectorySetProvider);
    final bookshelfState = ref.watch(bookshelfProvider);
    final bookshelfReady =
        !bootstrap.isLoading &&
        !bootstrap.hasError &&
        bootstrap.asData?.value != null;

    if (widget.feedId.isEmpty || widget.bookId.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.bookDetailTitle)),
        body: EmptyState(
          icon: Icons.info_outline,
          title: l10n.bookDetailMissingParams,
        ),
      );
    }

    final hasCurrentBook =
        bookInfoState.feedId == widget.feedId &&
        bookInfoState.bookId == widget.bookId;
    final currentBook = hasCurrentBook ? bookInfoState.book : null;
    final hasCurrentChapters =
        chaptersState.feedId == widget.feedId &&
        chaptersState.bookId == widget.bookId;
    final currentChaptersState = hasCurrentChapters
        ? chaptersState
        : const ChaptersState();
    final currentProgress =
        progressState.feedId == widget.feedId &&
            progressState.bookId == widget.bookId
        ? progressState.progress
        : null;

    if ((!hasCurrentBook || bookInfoState.isLoading) && currentBook == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.bookDetailTitle)),
        body: SizedBox(
          width: double.infinity,
          child: Column(
            children: [
              const SizedBox(height: LanghuanTheme.spaceMd),
              _buildHeroCover(widget.initialBook?.coverUrl),
              const SizedBox(height: LanghuanTheme.spaceLg),
              if (widget.initialBook?.title case final title?)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: LanghuanTheme.spaceLg,
                  ),
                  child: BookTextHero(
                    tag: bookTitleHeroTag(widget.feedId, widget.bookId),
                    child: Text(
                      title,
                      style: theme.textTheme.headlineMedium,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              if (widget.initialBook?.author case final author?) ...[
                const SizedBox(height: LanghuanTheme.spaceXs),
                BookTextHero(
                  tag: bookAuthorHeroTag(widget.feedId, widget.bookId),
                  child: Text(
                    author,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
              const Spacer(),
              const LanghuanSpinner(),
              const Spacer(),
            ],
          ),
        ),
      );
    }

    if (bookInfoState.hasError && bookInfoState.book == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.bookDetailTitle)),
        body: ErrorState(
          title: l10n.bookDetailError,
          message: normalizeErrorMessage(bookInfoState.error!),
          onRetry: () async {
            await ref.read(bookInfoProvider.notifier).retry();
            await ref
                .read(chaptersProvider.notifier)
                .load(feedId: widget.feedId, bookId: widget.bookId);
          },
          retryLabel: l10n.bookDetailRetry,
        ),
      );
    }

    final book = currentBook;
    if (book == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.bookDetailTitle)),
        body: EmptyState(
          icon: Icons.menu_book_outlined,
          title: l10n.bookDetailEmpty,
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.bookDetailTitle)),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              LanghuanTheme.spaceLg,
              LanghuanTheme.spaceMd,
              LanghuanTheme.spaceLg,
              LanghuanTheme.spaceMd,
            ),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(child: _buildHeroCover(book.coverUrl)),
                  const SizedBox(height: LanghuanTheme.spaceLg),
                  Center(
                    child: BookTextHero(
                      tag: bookTitleHeroTag(widget.feedId, widget.bookId),
                      child: Text(
                        book.title,
                        style: theme.textTheme.headlineMedium,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                  const SizedBox(height: LanghuanTheme.spaceXs),
                  Center(
                    child: BookTextHero(
                      tag: bookAuthorHeroTag(widget.feedId, widget.bookId),
                      child: Text(
                        book.author,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                  const SizedBox(height: LanghuanTheme.spaceMd),
                  Text(
                    (book.description == null || book.description!.isEmpty)
                        ? l10n.bookDetailNoDescription
                        : book.description!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: LanghuanTheme.spaceLg),
                  SizedBox(
                    width: double.infinity,
                    child:
                        bookshelfState.contains(
                          feedId: widget.feedId,
                          sourceBookId: widget.bookId,
                        )
                        ? OutlinedButton(
                            onPressed:
                                !bookshelfReady ||
                                    bookshelfState.activeItemId ==
                                        '${widget.feedId}:${widget.bookId}'
                                ? null
                                : () => _removeFromBookshelf(context),
                            child: Text(l10n.bookDetailRemoveBookshelf),
                          )
                        : FilledButton.tonal(
                            onPressed:
                                !bookshelfReady ||
                                    bookshelfState.activeItemId ==
                                        '${widget.feedId}:${widget.bookId}'
                                ? null
                                : () => _addToBookshelf(context),
                            child: Text(l10n.bookDetailAddBookshelf),
                          ),
                  ),
                  const SizedBox(height: LanghuanTheme.spaceMd),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: currentChaptersState.items.isEmpty
                          ? null
                          : () => _openReader(context, ''),
                      child: Text(
                        currentProgress != null
                            ? l10n.bookDetailContinueReading
                            : l10n.bookDetailStartReading,
                      ),
                    ),
                  ),
                  if (currentProgress != null &&
                      currentChaptersState.items.any(
                        (c) => c.id == currentProgress.chapterId,
                      ))
                    Padding(
                      padding: const EdgeInsets.only(
                        top: LanghuanTheme.spaceXs,
                      ),
                      child: Text(
                        l10n.bookDetailLastReadChapter(
                          currentChaptersState.items
                              .firstWhere(
                                (c) => c.id == currentProgress.chapterId,
                              )
                              .title,
                        ),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  const SizedBox(height: LanghuanTheme.spaceXl),
                  Text(
                    l10n.bookDetailChapters(currentChaptersState.items.length),
                    style: theme.textTheme.titleLarge,
                  ),
                ],
              ),
            ),
          ),
          if (currentChaptersState.isLoading &&
              currentChaptersState.items.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: LanghuanTheme.spaceLg,
                ),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            )
          else if (currentChaptersState.hasError &&
              currentChaptersState.items.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: LanghuanTheme.spaceLg,
                ),
                child: ErrorState(
                  title: l10n.bookDetailChaptersError,
                  message: normalizeErrorMessage(currentChaptersState.error!),
                  onRetry: () => ref
                      .read(chaptersProvider.notifier)
                      .retry(feedId: widget.feedId),
                  retryLabel: l10n.bookDetailRetry,
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                LanghuanTheme.spaceLg,
                LanghuanTheme.spaceMd,
                LanghuanTheme.spaceLg,
                LanghuanTheme.spaceLg,
              ),
              sliver: SliverList.builder(
                itemCount: currentChaptersState.items.length,
                itemBuilder: (context, index) {
                  final chapter = currentChaptersState.items[index];
                  final isLastRead =
                      currentProgress != null &&
                      currentProgress.chapterId == chapter.id;
                  return Padding(
                    padding: const EdgeInsets.only(
                      bottom: LanghuanTheme.spaceSm,
                    ),
                    child: Material(
                      color: isLastRead
                          ? theme.colorScheme.primaryContainer
                          : theme.colorScheme.surfaceContainer,
                      borderRadius: LanghuanTheme.borderRadiusMd,
                      child: ListTile(
                        onTap: () => _openReader(context, chapter.id),
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: LanghuanTheme.spaceMd,
                          vertical: LanghuanTheme.spaceXs,
                        ),
                        title: Text(
                          chapter.title,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: isLastRead
                                ? theme.colorScheme.onPrimaryContainer
                                : null,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        leading: Text(
                          '${index + 1}',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: isLastRead
                                ? theme.colorScheme.onPrimaryContainer
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        trailing: isLastRead
                            ? Icon(
                                Icons.bookmark,
                                size: 18,
                                color: theme.colorScheme.onPrimaryContainer,
                              )
                            : null,
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildHeroCover(String? coverUrl) {
    final stableCoverUrl = widget.initialBook?.coverUrl ?? coverUrl;
    return Hero(
      tag: bookCoverHeroTag(widget.feedId, widget.bookId),
      flightShuttleBuilder: bookCoverFlightShuttleBuilder,
      child: ClipRRect(
        borderRadius: LanghuanTheme.borderRadiusMd,
        child: SizedBox(
          width: 120,
          height: 160,
          child: stableCoverUrl != null
              ? CoverImage(
                  url: stableCoverUrl,
                  width: 120,
                  height: 160,
                  placeholder: const _LargeCoverPlaceholder(),
                )
              : BookCover(
                  feedId: widget.feedId,
                  bookId: widget.bookId,
                  url: coverUrl,
                  width: 120,
                  height: 160,
                  placeholder: const _LargeCoverPlaceholder(),
                ),
        ),
      ),
    );
  }

  Future<void> _addToBookshelf(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final bootstrap = ref.read(appDataDirectorySetProvider);
    if (bootstrap.isLoading ||
        bootstrap.hasError ||
        bootstrap.asData?.value == null) {
      if (!context.mounted) return;
      showErrorSnack(ScaffoldMessenger.of(context), l10n.bookshelfActionFailed);
      return;
    }

    // Snapshot the currently displayed info so the shelf renders instantly.
    final book = ref.read(bookInfoProvider).book;
    try {
      await ref
          .read(bookshelfProvider.notifier)
          .add(
            feedId: widget.feedId,
            sourceBookId: widget.bookId,
            title: book?.title ?? widget.bookId,
            author: book?.author ?? '',
            coverUrl: book?.coverUrl,
            description: book?.description,
          );
      if (!context.mounted) return;
      showSuccessSnack(ScaffoldMessenger.of(context), l10n.bookshelfAdded);
    } catch (_) {
      if (!context.mounted) return;
      showErrorSnack(ScaffoldMessenger.of(context), l10n.bookshelfActionFailed);
    }
  }

  Future<void> _removeFromBookshelf(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final bootstrap = ref.read(appDataDirectorySetProvider);
    if (bootstrap.isLoading ||
        bootstrap.hasError ||
        bootstrap.asData?.value == null) {
      if (!context.mounted) return;
      showErrorSnack(ScaffoldMessenger.of(context), l10n.bookshelfActionFailed);
      return;
    }

    final bookState = ref.read(bookInfoProvider);
    final hasCurrentBook =
        bookState.feedId == widget.feedId && bookState.bookId == widget.bookId;
    final title = hasCurrentBook && bookState.book != null
        ? bookState.book!.title
        : widget.initialBook?.title ?? widget.bookId;
    final confirmed = await showConfirmDialog(
      context,
      title: l10n.bookshelfDeleteConfirmTitle,
      message: l10n.bookshelfDeleteConfirmMessage(title),
      warning: l10n.bookshelfDeleteCascadeWarning,
      confirmLabel: l10n.bookshelfDeleteConfirm,
      cancelLabel: l10n.bookshelfDeleteCancel,
    );
    if (!confirmed || !context.mounted) return;

    try {
      await ref
          .read(bookshelfProvider.notifier)
          .remove(feedId: widget.feedId, sourceBookId: widget.bookId);
      if (!context.mounted) return;
      showSuccessSnack(ScaffoldMessenger.of(context), l10n.bookshelfRemoved);
    } catch (_) {
      if (!context.mounted) return;
      showErrorSnack(ScaffoldMessenger.of(context), l10n.bookshelfActionFailed);
    }
  }
}

class _LargeCoverPlaceholder extends StatelessWidget {
  const _LargeCoverPlaceholder();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: const CoverPlaceholder(),
    );
  }
}

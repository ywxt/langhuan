import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/app_localizations.dart';
import '../../rust_init.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/cover_image.dart';
import '../../shared/widgets/cover_placeholder.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/error_state.dart';
import 'book_providers.dart';
import 'bookshelf_provider.dart';
import '../feeds/feed_service.dart';
import 'reading_progress_provider.dart';
import 'widgets/reader_types.dart';

class BookDetailPage extends ConsumerStatefulWidget {
  const BookDetailPage({super.key, required this.feedId, required this.bookId});

  final String feedId;
  final String bookId;

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
      if (!mounted) return;
      _load();
    });
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

    if (bookInfoState.isLoading && bookInfoState.book == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.bookDetailTitle)),
        body: const Center(child: CircularProgressIndicator()),
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

    final book = bookInfoState.book;
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
                  Center(
                    child: Hero(
                      tag: 'book-cover-${widget.feedId}-${widget.bookId}',
                      child: ClipRRect(
                        borderRadius: LanghuanTheme.borderRadiusMd,
                        child: SizedBox(
                          width: 120,
                          height: 160,
                          child: book.coverUrl == null
                              ? const _LargeCoverPlaceholder()
                              : CoverImage(
                                  url: book.coverUrl!,
                                  placeholder: const _LargeCoverPlaceholder(),
                                ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: LanghuanTheme.spaceLg),
                  Text(book.title, style: theme.textTheme.headlineMedium),
                  const SizedBox(height: LanghuanTheme.spaceXs),
                  Text(
                    book.author,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
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
                      onPressed: chaptersState.items.isEmpty
                          ? null
                          : () => _openReader(context, ''),
                      child: Text(
                        progressState.progress != null
                            ? l10n.bookDetailContinueReading
                            : l10n.bookDetailStartReading,
                      ),
                    ),
                  ),
                  if (progressState.progress != null &&
                      chaptersState.items.any(
                        (c) => c.id == progressState.progress!.chapterId,
                      ))
                    Padding(
                      padding: const EdgeInsets.only(top: LanghuanTheme.spaceXs),
                      child: Text(
                        l10n.bookDetailLastReadChapter(
                          chaptersState.items
                              .firstWhere(
                                (c) => c.id == progressState.progress!.chapterId,
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
                    l10n.bookDetailChapters(chaptersState.items.length),
                    style: theme.textTheme.titleLarge,
                  ),
                ],
              ),
            ),
          ),
          if (chaptersState.isLoading && chaptersState.items.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: LanghuanTheme.spaceLg),
                child: LinearProgressIndicator(),
              ),
            )
          else if (chaptersState.hasError && chaptersState.items.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: LanghuanTheme.spaceLg),
                child: ErrorState(
                  title: l10n.bookDetailChaptersError,
                  message: normalizeErrorMessage(chaptersState.error!),
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
                itemCount: chaptersState.items.length,
                itemBuilder: (context, index) {
                  final chapter = chaptersState.items[index];
                  final isLastRead =
                      progressState.progress != null &&
                      progressState.progress!.chapterId == chapter.id;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: LanghuanTheme.spaceSm),
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

  Future<void> _addToBookshelf(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final bootstrap = ref.read(appDataDirectorySetProvider);
    if (bootstrap.isLoading ||
        bootstrap.hasError ||
        bootstrap.asData?.value == null) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(l10n.bookshelfActionFailed)));
      return;
    }

    final outcome = await ref
        .read(bookshelfProvider.notifier)
        .add(feedId: widget.feedId, sourceBookId: widget.bookId);

    if (!context.mounted) return;
    final text = outcome is BookshelfOperationOutcomeError
        ? l10n.bookshelfActionFailed
        : l10n.bookshelfAdded;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _removeFromBookshelf(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final bootstrap = ref.read(appDataDirectorySetProvider);
    if (bootstrap.isLoading ||
        bootstrap.hasError ||
        bootstrap.asData?.value == null) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(l10n.bookshelfActionFailed)));
      return;
    }

    final outcome = await ref
        .read(bookshelfProvider.notifier)
        .remove(feedId: widget.feedId, sourceBookId: widget.bookId);

    if (!context.mounted) return;
    final text = outcome is BookshelfOperationOutcomeError
        ? l10n.bookshelfActionFailed
        : l10n.bookshelfRemoved;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
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

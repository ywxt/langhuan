import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/cover_placeholder.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/error_state.dart';
import '../feeds/feed_providers.dart';

class BookDetailPage extends ConsumerStatefulWidget {
  const BookDetailPage({super.key, required this.feedId, required this.bookId});

  final String feedId;
  final String bookId;

  @override
  ConsumerState<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends ConsumerState<BookDetailPage> {
  void _openReader(BuildContext context, String chapterId) {
    context.pushNamed(
      'bookshelf-reader',
      queryParameters: {
        'feedId': widget.feedId,
        'bookId': widget.bookId,
        'chapterId': chapterId,
      },
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _load();
    });
  }

  Future<void> _load() async {
    if (widget.feedId.isEmpty || widget.bookId.isEmpty) return;

    await ref
        .read(bookInfoProvider.notifier)
        .load(feedId: widget.feedId, bookId: widget.bookId);
    await ref
        .read(chaptersProvider.notifier)
        .load(feedId: widget.feedId, bookId: widget.bookId);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final bookInfoState = ref.watch(bookInfoProvider);
    final chaptersState = ref.watch(chaptersProvider);

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
          message: bookInfoState.error.toString(),
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
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          LanghuanTheme.spaceLg,
          LanghuanTheme.spaceMd,
          LanghuanTheme.spaceLg,
          LanghuanTheme.spaceLg,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: ClipRRect(
                borderRadius: LanghuanTheme.borderRadiusMd,
                child: SizedBox(
                  width: 120,
                  height: 160,
                  child: book.coverUrl == null
                      ? const _LargeCoverPlaceholder()
                      : Image.network(
                          book.coverUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) =>
                              const _LargeCoverPlaceholder(),
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
              child: FilledButton(
                onPressed: chaptersState.items.isEmpty
                    ? null
                    : () => _openReader(context, chaptersState.items.first.id),
                child: Text(l10n.bookDetailStartReading),
              ),
            ),
            const SizedBox(height: LanghuanTheme.spaceXl),
            Text(
              l10n.bookDetailChapters(chaptersState.items.length),
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: LanghuanTheme.spaceMd),
            if (chaptersState.isLoading && chaptersState.items.isEmpty)
              const LinearProgressIndicator()
            else if (chaptersState.hasError && chaptersState.items.isEmpty)
              ErrorState(
                title: l10n.bookDetailChaptersError,
                message: chaptersState.error.toString(),
                onRetry: () => ref
                    .read(chaptersProvider.notifier)
                    .retry(feedId: widget.feedId),
                retryLabel: l10n.bookDetailRetry,
              )
            else
              ...chaptersState.items.map(
                (chapter) => Padding(
                  padding: const EdgeInsets.only(bottom: LanghuanTheme.spaceSm),
                  child: Material(
                    color: theme.colorScheme.surfaceContainer,
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
                        style: theme.textTheme.bodyLarge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      leading: Text(
                        '${chapter.index + 1}',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
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

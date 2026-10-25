import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/utils/always_disabled_focus_node.dart';
import '../../shared/widgets/cover_placeholder.dart';
import '../../shared/widgets/empty_state.dart';
import '../feeds/feed_service.dart';
import 'book_detail_page.dart';
import 'bookshelf_provider.dart';
import 'widgets/book_cover.dart';
import 'widgets/book_cover_hero.dart';

enum _BookshelfAction { details, delete }

class BookshelfPage extends ConsumerWidget {
  const BookshelfPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(bookshelfProvider);

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => ref.read(bookshelfProvider.notifier).load(),
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            slivers: [
              // ── Title ──────────────────────────────────────────────────
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  LanghuanTheme.spaceLg,
                  LanghuanTheme.spaceLg,
                  LanghuanTheme.spaceLg,
                  LanghuanTheme.spaceMd,
                ),
                sliver: SliverToBoxAdapter(
                  child: Text(
                    l10n.bookshelfTitle,
                    style: theme.textTheme.headlineLarge,
                  ),
                ),
              ),

              // ── Search bar (tap to navigate) ───────────────────────────
              SliverPadding(
                padding: const EdgeInsets.symmetric(
                  horizontal: LanghuanTheme.spaceLg,
                ),
                sliver: SliverToBoxAdapter(
                  child: SearchBar(
                    hintText: l10n.bookshelfSearchHint,
                    leading: Icon(
                      Icons.search,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    onTap: () => context.push('/bookshelf/search'),
                    focusNode: AlwaysDisabledFocusNode(),
                  ),
                ),
              ),

              const SliverToBoxAdapter(
                child: SizedBox(height: LanghuanTheme.spaceLg),
              ),

              if (state.isLoading && state.items.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (state.hasError && state.items.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    icon: Icons.error_outline,
                    title: l10n.bookshelfLoadError,
                    subtitle: state.error.toString(),
                  ),
                )
              else if (state.items.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    icon: Icons.auto_stories_outlined,
                    title: l10n.bookshelfEmpty,
                    subtitle: l10n.bookshelfEmptyHint,
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: LanghuanTheme.spaceLg,
                  ),
                  sliver: SliverList.separated(
                    itemBuilder: (context, index) {
                      final item = state.items[index];
                      return Material(
                        color: theme.colorScheme.surfaceContainer,
                        borderRadius: LanghuanTheme.borderRadiusMd,
                        child: ListTile(
                          onTap: () {
                            context.pushNamed(
                              'bookshelf-reader',
                              queryParameters: {
                                'feedId': item.feedId,
                                'bookId': item.sourceBookId,
                                'chapterId': '',
                                'paragraphId': '',
                              },
                            );
                          },
                          onLongPress: () =>
                              _showBookActions(context, ref, item),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: LanghuanTheme.spaceMd,
                            vertical: LanghuanTheme.spaceXs,
                          ),
                          leading: Hero(
                            tag: bookCoverHeroTag(
                              item.feedId,
                              item.sourceBookId,
                            ),
                            flightShuttleBuilder: bookCoverFlightShuttleBuilder,
                            child: ClipRRect(
                              borderRadius: LanghuanTheme.borderRadiusSm,
                              child: SizedBox(
                                width: 44,
                                height: 60,
                                child: BookCover(
                                  feedId: item.feedId,
                                  bookId: item.sourceBookId,
                                  url: item.coverUrl,
                                  placeholder: const _SmallCoverPlaceholder(),
                                ),
                              ),
                            ),
                          ),
                          title: BookTextHero(
                            tag: bookTitleHeroTag(
                              item.feedId,
                              item.sourceBookId,
                            ),
                            child: Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyLarge,
                            ),
                          ),
                          subtitle: BookTextHero(
                            tag: bookAuthorHeroTag(
                              item.feedId,
                              item.sourceBookId,
                            ),
                            child: Text(
                              item.author,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: LanghuanTheme.spaceSm),
                    itemCount: state.items.length,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showBookActions(
    BuildContext context,
    WidgetRef ref,
    BookshelfItemModel item,
  ) async {
    final l10n = AppLocalizations.of(context);
    final action = await showModalBottomSheet<_BookshelfAction>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final colorScheme = Theme.of(sheetContext).colorScheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: Text(l10n.bookshelfBookDetails),
                onTap: () =>
                    Navigator.pop(sheetContext, _BookshelfAction.details),
              ),
              ListTile(
                leading: Icon(Icons.delete_outline, color: colorScheme.error),
                title: Text(
                  l10n.bookshelfDeleteBook,
                  style: TextStyle(color: colorScheme.error),
                ),
                onTap: () =>
                    Navigator.pop(sheetContext, _BookshelfAction.delete),
              ),
              const SizedBox(height: LanghuanTheme.spaceSm),
            ],
          ),
        );
      },
    );

    if (!context.mounted || action == null) return;
    switch (action) {
      case _BookshelfAction.details:
        await context.pushNamed(
          'bookshelf-book-detail',
          queryParameters: {'feedId': item.feedId, 'bookId': item.sourceBookId},
          extra: BookDetailRouteExtra(
            coverUrl: item.coverUrl,
            title: item.title,
            author: item.author,
          ),
        );
        return;
      case _BookshelfAction.delete:
        await _confirmAndDelete(context, ref, item);
        return;
    }
  }

  Future<void> _confirmAndDelete(
    BuildContext context,
    WidgetRef ref,
    BookshelfItemModel item,
  ) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        return AlertDialog(
          title: Text(l10n.bookshelfDeleteConfirmTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.bookshelfDeleteConfirmMessage(item.title)),
              const SizedBox(height: LanghuanTheme.spaceSm),
              Text(
                l10n.bookshelfDeleteCascadeWarning,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(l10n.bookshelfDeleteCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.error,
                foregroundColor: theme.colorScheme.onError,
              ),
              child: Text(l10n.bookshelfDeleteConfirm),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !context.mounted) return;

    final outcome = await ref
        .read(bookshelfProvider.notifier)
        .remove(feedId: item.feedId, sourceBookId: item.sourceBookId);
    if (!context.mounted) return;
    final message = outcome is BookshelfOperationOutcomeError
        ? l10n.bookshelfActionFailed
        : l10n.bookshelfRemoved;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _SmallCoverPlaceholder extends StatelessWidget {
  const _SmallCoverPlaceholder();

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

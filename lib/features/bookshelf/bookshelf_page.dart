import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/constants.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/utils/always_disabled_focus_node.dart';
import '../../shared/utils/delete_with_undo.dart';
import '../../shared/utils/snackbars.dart';
import '../../shared/widgets/confirm_dialog.dart';
import '../../shared/widgets/cover_placeholder.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/loading.dart';
import '../../shared/widgets/swipe_action_card.dart';
import '../feeds/feed_service.dart';
import 'book_detail_page.dart';
import 'bookshelf_provider.dart';
import 'widgets/book_cover.dart';
import 'widgets/book_cover_hero.dart';

class BookshelfPage extends ConsumerStatefulWidget {
  const BookshelfPage({super.key});

  @override
  ConsumerState<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends ConsumerState<BookshelfPage> {
  final Set<String> _pendingDeleteIds = <String>{};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(bookshelfProvider);
    final updates = ref.watch(bookshelfUpdatesProvider);
    final visibleItems = state.items
        .where((item) => !_pendingDeleteIds.contains(item.stableId))
        .toList(growable: false);

    // One-shot feedback when a check run completes.
    ref.listen(bookshelfUpdatesProvider, (previous, next) {
      if (previous?.isChecking != true || next.isChecking) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;
      if (next.lastError != null) {
        showErrorSnack(messenger, l10n.bookshelfCheckFailed);
      } else if (next.failedBooks.isNotEmpty) {
        showErrorSnack(
          messenger,
          l10n.bookshelfCheckPartialFailure(next.failedBooks.length),
        );
      }
    });

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Title ──────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(
                LanghuanTheme.spaceLg,
                LanghuanTheme.spaceLg,
                LanghuanTheme.spaceLg,
                LanghuanTheme.spaceMd,
              ),
              child: Text(
                l10n.bookshelfTitle,
                style: theme.textTheme.headlineLarge,
              ),
            ),

            // ── Search bar (tap to navigate) ───────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: LanghuanTheme.spaceLg,
              ),
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

            const SizedBox(height: LanghuanTheme.spaceLg),

            // ── Book list ────────────────────────────────────────────────
            // The list is the only scrollable area, so pull-to-refresh is
            // scoped to the list rather than the whole page. Update checks
            // are triggered by that gesture; per-book badges and the
            // one-shot snackbar above provide the feedback.
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async {
                  await Future.wait([
                    ref.read(bookshelfProvider.notifier).load(),
                    ref.read(bookshelfUpdatesProvider.notifier).check(),
                  ]);
                },
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  slivers: [
                    if (state.isLoading && state.items.isEmpty)
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: LoadingState(),
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
                    else if (visibleItems.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: EmptyState(
                          icon: Icons.auto_stories_outlined,
                          title: l10n.bookshelfEmpty,
                          subtitle: l10n.bookshelfEmptyHint,
                        ),
                      )
                    else ...[
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: LanghuanTheme.spaceLg,
                        ),
                        sliver: SliverList.separated(
                          itemBuilder: (context, index) {
                            final item = visibleItems[index];
                            return SwipeActionCard(
                              dismissKey: ValueKey(
                                'bookshelf-${item.stableId}',
                              ),
                              enabled: _pendingDeleteIds.isEmpty,
                              confirmDismiss: (_) async {
                                final confirmed = await _confirmDelete(
                                  context,
                                  item,
                                );
                                if (confirmed && context.mounted) {
                                  _handleDeleteWithUndo(
                                    item,
                                    ScaffoldMessenger.of(context),
                                  );
                                }
                                return false;
                              },
                              child: Material(
                                color: theme.colorScheme.surfaceContainer,
                                child: ListTile(
                                  onTap: () => _openReader(item),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: LanghuanTheme.spaceMd,
                                    vertical: LanghuanTheme.spaceXs,
                                  ),
                                  leading: Hero(
                                    tag: bookCoverHeroTag(
                                      item.feedId,
                                      item.sourceBookId,
                                    ),
                                    flightShuttleBuilder:
                                        bookCoverFlightShuttleBuilder,
                                    child: ClipRRect(
                                      borderRadius:
                                          LanghuanTheme.borderRadiusSm,
                                      child: SizedBox(
                                        width: 44,
                                        height: 60,
                                        child: BookCover(
                                          feedId: item.feedId,
                                          bookId: item.sourceBookId,
                                          url: item.coverUrl,
                                          placeholder:
                                              const _SmallCoverPlaceholder(),
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
                                  subtitle: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      BookTextHero(
                                        tag: bookAuthorHeroTag(
                                          item.feedId,
                                          item.sourceBookId,
                                        ),
                                        child: Text(
                                          item.author,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodyMedium
                                              ?.copyWith(
                                                color: theme
                                                    .colorScheme
                                                    .onSurfaceVariant,
                                              ),
                                        ),
                                      ),
                                      if (item.progressFraction
                                          case final value?)
                                        _ReadingProgress(
                                          item: item,
                                          value: value,
                                          l10n: l10n,
                                        ),
                                    ],
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (!item.feedEnabled)
                                        Tooltip(
                                          message: l10n.bookshelfFeedPausedHint,
                                          child: Padding(
                                            padding: const EdgeInsets.only(
                                              right: LanghuanTheme.spaceXs,
                                            ),
                                            child: Icon(
                                              Icons.pause_circle_outline,
                                              size: 20,
                                              color: theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                              semanticLabel:
                                                  l10n.bookshelfFeedPaused,
                                            ),
                                          ),
                                        ),
                                      _UpdateBadge(
                                        count:
                                            updates.newChaptersByBook[item
                                                .stableId] ??
                                            0,
                                        l10n: l10n,
                                      ),
                                      IconButton(
                                        tooltip: l10n.bookshelfBookDetails,
                                        icon: const Icon(Icons.info_outline),
                                        onPressed: () => _openDetails(item),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: LanghuanTheme.spaceSm),
                          itemCount: visibleItems.length,
                        ),
                      ),
                      const SliverToBoxAdapter(
                        child: SizedBox(height: LanghuanTheme.spaceLg),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openReader(BookshelfItemModel item) async {
    await context.pushNamed(
      'bookshelf-reader',
      queryParameters: {
        'feedId': item.feedId,
        'bookId': item.sourceBookId,
        'chapterId': '',
        'paragraphId': '',
      },
    );
    if (mounted) await ref.read(bookshelfProvider.notifier).load();
  }

  Future<void> _openDetails(BookshelfItemModel item) async {
    await context.pushNamed(
      'bookshelf-book-detail',
      queryParameters: {'feedId': item.feedId, 'bookId': item.sourceBookId},
      extra: BookDetailRouteExtra(
        coverUrl: item.coverUrl,
        title: item.title,
        author: item.author,
      ),
    );
    if (mounted) await ref.read(bookshelfProvider.notifier).load();
  }

  Future<bool> _confirmDelete(BuildContext context, BookshelfItemModel item) {
    final l10n = AppLocalizations.of(context);
    return showConfirmDialog(
      context,
      title: l10n.bookshelfDeleteConfirmTitle,
      message: l10n.bookshelfDeleteConfirmMessage(item.title),
      warning: l10n.bookshelfDeleteCascadeWarning,
      confirmLabel: l10n.bookshelfDeleteConfirm,
      cancelLabel: l10n.bookshelfDeleteCancel,
    );
  }

  Future<void> _handleDeleteWithUndo(
    BookshelfItemModel item,
    ScaffoldMessengerState messenger,
  ) async {
    final l10n = AppLocalizations.of(context);
    setState(() => _pendingDeleteIds.add(item.stableId));

    final undone = await deleteWithUndo(
      messenger: messenger,
      message: l10n.bookshelfDeleteQueued(item.title),
      undoLabel: l10n.bookshelfDeleteUndo,
      duration: AppConstants.undoDuration,
    );
    if (!mounted) return;
    if (undone) {
      setState(() => _pendingDeleteIds.remove(item.stableId));
      messenger.clearSnackBars();
      return;
    }

    try {
      await ref
          .read(bookshelfProvider.notifier)
          .remove(feedId: item.feedId, sourceBookId: item.sourceBookId);
      ref
          .read(bookshelfUpdatesProvider.notifier)
          .remove(item.feedId, item.sourceBookId);
      if (!mounted) return;
      showSuccessSnack(ScaffoldMessenger.of(context), l10n.bookshelfRemoved);
    } catch (_) {
      if (!mounted) return;
      showErrorSnack(ScaffoldMessenger.of(context), l10n.bookshelfActionFailed);
    } finally {
      if (mounted) {
        setState(() => _pendingDeleteIds.remove(item.stableId));
      }
    }
  }
}

/// Where the reader stopped: the current chapter's title plus the overall
/// percentage, e.g. "Frostfall · 34%".
class _ReadingProgress extends StatelessWidget {
  const _ReadingProgress({
    required this.item,
    required this.value,
    required this.l10n,
  });

  final BookshelfItemModel item;
  final double value;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final percent = (value * 100).round();
    final chapterTitle = item.progressChapterTitleOrNull;
    final label = chapterTitle != null
        ? l10n.bookshelfReadingProgressWithChapter(chapterTitle, percent)
        : l10n.bookshelfReadingProgress(
            item.progressCurrentChapter!,
            item.progressTotalChapters!,
            percent,
          );

    return Padding(
      padding: const EdgeInsets.only(top: LanghuanTheme.spaceXs),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Red pill badge showing the number of new chapters for a shelved book.
class _UpdateBadge extends StatelessWidget {
  const _UpdateBadge({required this.count, required this.l10n});

  final int count;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: l10n.bookshelfNewChapters(count),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: LanghuanTheme.spaceSm,
          vertical: LanghuanTheme.spaceXs,
        ),
        decoration: BoxDecoration(
          color: scheme.error,
          borderRadius: BorderRadius.circular(LanghuanTheme.radiusXl),
        ),
        child: Text(
          count.toString(),
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: scheme.onError,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
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

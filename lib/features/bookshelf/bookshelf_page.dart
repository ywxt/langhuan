import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/utils/always_disabled_focus_node.dart';
import '../../shared/widgets/cover_placeholder.dart';
import '../../shared/widgets/empty_state.dart';
import '../feeds/feed_providers.dart';

class BookshelfPage extends ConsumerWidget {
  const BookshelfPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(bookshelfProvider);

    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
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
                            'bookshelf-book-detail',
                            queryParameters: {
                              'feedId': item.feedId,
                              'bookId': item.sourceBookId,
                            },
                          );
                        },
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: LanghuanTheme.spaceMd,
                          vertical: LanghuanTheme.spaceXs,
                        ),
                        leading: ClipRRect(
                          borderRadius: LanghuanTheme.borderRadiusSm,
                          child: SizedBox(
                            width: 44,
                            height: 60,
                            child: item.coverUrl == null
                                ? const _SmallCoverPlaceholder()
                                : Image.network(
                                    item.coverUrl!,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) =>
                                        const _SmallCoverPlaceholder(),
                                  ),
                          ),
                        ),
                        title: Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge,
                        ),
                        subtitle: Text(
                          item.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
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

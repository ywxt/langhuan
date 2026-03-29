import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/utils/always_disabled_focus_node.dart';
import '../../shared/widgets/empty_state.dart';

class BookshelfPage extends StatelessWidget {
  const BookshelfPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

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

            // ── Content ────────────────────────────────────────────────
            // TODO: Replace with book grid when bookshelf has items
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: Icons.auto_stories_outlined,
                title: l10n.bookshelfEmpty,
                subtitle: l10n.bookshelfEmptyHint,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

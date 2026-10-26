import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/utils/errors.dart';
import '../../../shared/utils/snackbars.dart';
import '../../../shared/widgets/meta_row.dart';
import '../../../src/rust/api/types.dart';
import '../../bookshelf/bookshelf_provider.dart';
import '../feed_providers.dart';
import '../feed_service.dart';
import 'feed_visuals.dart';

/// Opens a modal bottom sheet with a feed's details and management
/// actions.
void showFeedDetailSheet(
  BuildContext context,
  FeedMetaItem feed, {
  Future<void> Function()? onDelete,
}) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => FeedDetailSheet(feed: feed, onDelete: onDelete),
  );
}

/// Bottom sheet carrying a feed's full metadata and management actions:
/// pause/resume, login/logout, ID copy, and deletion.
///
/// While open, the sheet follows the live feed list — pausing from the
/// list or from the sheet itself updates it instantly, and a feed that
/// disappears from the list closes it. The list card, by contrast, is a
/// compact identity-and-status summary.
class FeedDetailSheet extends ConsumerStatefulWidget {
  const FeedDetailSheet({super.key, required this.feed, this.onDelete});

  final FeedMetaItem feed;

  /// Hands over to the page-level delete flow (confirm dialog + undo
  /// snackbar) after the sheet has closed itself. When null, the delete
  /// action is hidden.
  final Future<void> Function()? onDelete;

  @override
  ConsumerState<FeedDetailSheet> createState() => _FeedDetailSheetState();
}

class _FeedDetailSheetState extends ConsumerState<FeedDetailSheet> {
  bool _toggling = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    // The live item from the feed list is the source of truth, so toggles
    // from the card or from this sheet are reflected immediately.
    final feedState = ref.watch(feedListProvider);
    FeedMetaItem? live;
    for (final candidate in feedState.items) {
      if (candidate.id == widget.feed.id) {
        live = candidate;
        break;
      }
    }

    // The feed vanished underneath us (deleted elsewhere): close quietly.
    // A loading list momentarily clears its items, so only act once it
    // has settled.
    ref.listen(feedListProvider, (_, next) {
      if (next.isLoading) return;
      final stillPresent = next.items.any((f) => f.id == widget.feed.id);
      if (!stillPresent && mounted) Navigator.of(context).maybePop();
    });

    final feed = live ?? widget.feed;
    final hasError = feed.error != null;
    final authAsync = ref.watch(feedAuthStatusProvider(feed.id));
    final shelf = ref.watch(bookshelfProvider);
    final bookCount = shelf.items
        .where((item) => item.feedId == feed.id)
        .length;

    // A failed auth probe (for example while offline) must not hide the
    // login action for an auth-capable feed — fall back to "logged out".
    final authSupported =
        !authAsync.isLoading && (authAsync.hasError || authAsync.value != null);
    final authStatus = authAsync.hasError
        ? FeedAuthStatusModel.loggedOut
        : authAsync.value;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          LanghuanTheme.spaceLg,
          0,
          LanghuanTheme.spaceLg,
          LanghuanTheme.spaceXl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Header ────────────────────────────────────────────────
            Row(
              children: [
                FeedAvatar(feed: feed, size: 48),
                const SizedBox(width: LanghuanTheme.spaceMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(
                          feed.name,
                          style: theme.textTheme.titleLarge,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        feed.author != null
                            ? 'v${feed.version} · ${feed.author}'
                            : 'v${feed.version}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),

            if (hasError) ...[
              const SizedBox(height: LanghuanTheme.spaceMd),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(LanghuanTheme.spaceMd),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: LanghuanTheme.borderRadiusMd,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 18,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: LanghuanTheme.spaceSm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.feedItemLoadError,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onErrorContainer,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            feed.error!,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onErrorContainer,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // ── Enable switch ─────────────────────────────────────────
            const SizedBox(height: LanghuanTheme.spaceMd),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.feedDetailEnabled),
              subtitle: Text(l10n.feedDetailEnabledHint),
              value: feed.enabled,
              onChanged: _toggling ? null : _handleToggle,
            ),

            const SizedBox(height: LanghuanTheme.spaceSm),
            const Divider(),
            const SizedBox(height: LanghuanTheme.spaceMd),

            // ── Metadata ──────────────────────────────────────────────
            // Version and author live in the header; this section carries
            // what the header does not.
            MetaRow(
              icon: Icons.auto_stories_outlined,
              label: l10n.feedDetailBooksLabel,
              value: l10n.feedDetailBookCount(bookCount),
            ),
            if (feed.baseUrl case final baseUrl?) ...[
              const SizedBox(height: LanghuanTheme.spaceMd),
              MetaRow(
                icon: Icons.link,
                label: l10n.feedDetailBaseUrl,
                value: baseUrl,
              ),
              const SizedBox(height: LanghuanTheme.spaceMd),
              _AccessDomains(domains: feed.accessDomains),
            ],
            if (feed.sourceUrl case final sourceUrl?) ...[
              const SizedBox(height: LanghuanTheme.spaceMd),
              MetaRow(
                icon: Icons.download_outlined,
                label: l10n.feedDetailSource,
                value: sourceUrl,
              ),
            ],
            const SizedBox(height: LanghuanTheme.spaceMd),
            Row(
              children: [
                Expanded(
                  child: MetaRow(
                    icon: Icons.label_outline,
                    label: l10n.feedDetailId,
                    value: feed.id,
                  ),
                ),
                IconButton(
                  tooltip: l10n.feedDetailCopyId,
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  onPressed: () => _copyId(feed.id),
                ),
              ],
            ),

            // ── Auth ──────────────────────────────────────────────────
            if (authSupported) ...[
              const SizedBox(height: LanghuanTheme.spaceSm),
              const Divider(),
              const SizedBox(height: LanghuanTheme.spaceMd),
              Row(
                children: [
                  Icon(
                    Icons.lock_outline,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: LanghuanTheme.spaceSm),
                  Text(
                    l10n.feedAuthLabel,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (authStatus != null) ...[
                    const SizedBox(width: LanghuanTheme.spaceSm),
                    FeedAuthBadge(status: authStatus),
                  ],
                ],
              ),
              const SizedBox(height: LanghuanTheme.spaceMd),
              Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: authAsync.isLoading ? null : _openLoginFlow,
                    icon: const Icon(Icons.login),
                    label: Text(l10n.feedAuthLogin),
                  ),
                  const SizedBox(width: LanghuanTheme.spaceSm),
                  OutlinedButton.icon(
                    onPressed:
                        authAsync.isLoading ||
                            authStatus == FeedAuthStatusModel.loggedOut
                        ? null
                        : _logout,
                    icon: const Icon(Icons.logout),
                    label: Text(l10n.feedAuthLogout),
                  ),
                ],
              ),
            ],

            // ── Danger zone ───────────────────────────────────────────
            if (widget.onDelete != null) ...[
              const SizedBox(height: LanghuanTheme.spaceLg),
              const Divider(),
              const SizedBox(height: LanghuanTheme.spaceMd),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                  side: BorderSide(color: theme.colorScheme.error),
                ),
                onPressed: _delete,
                icon: const Icon(Icons.delete_outline),
                label: Text(l10n.feedDetailDelete),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _handleToggle(bool value) async {
    setState(() => _toggling = true);
    try {
      final error = await ref
          .read(feedListProvider.notifier)
          .setFeedEnabled(feedId: widget.feed.id, enabled: value);
      if (error != null && mounted) {
        final l10n = AppLocalizations.of(context);
        showErrorSnack(
          ScaffoldMessenger.of(context),
          '${l10n.feedToggleError}: ${normalizeErrorMessage(error)}',
        );
      }
    } finally {
      if (mounted) setState(() => _toggling = false);
    }
  }

  Future<void> _copyId(String id) async {
    await Clipboard.setData(ClipboardData(text: id));
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    showSuccessSnack(ScaffoldMessenger.of(context), l10n.feedDetailCopied);
  }

  Future<void> _openLoginFlow() async {
    final navigator = GoRouter.of(context);
    final result = await navigator.pushNamed<bool>(
      'feed-auth',
      queryParameters: {'feedId': widget.feed.id},
    );
    if (result == true && mounted) {
      ref.invalidate(feedAuthStatusProvider(widget.feed.id));
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      showSuccessSnack(ScaffoldMessenger.of(context), l10n.feedAuthUpdated);
    }
  }

  Future<void> _logout() async {
    try {
      await ref.read(feedServiceProvider).clearFeedAuth(widget.feed.id);
      ref.invalidate(feedAuthStatusProvider(widget.feed.id));
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      showSuccessSnack(ScaffoldMessenger.of(context), l10n.feedAuthLoggedOut);
    } catch (e) {
      if (!mounted) return;
      showErrorSnack(ScaffoldMessenger.of(context), normalizeErrorMessage(e));
    }
  }

  /// Close the sheet first, then hand control to the page-level flow so
  /// the confirm dialog and undo snackbar appear over the feed list.
  Future<void> _delete() async {
    final onDelete = widget.onDelete;
    Navigator.of(context).pop();
    if (onDelete != null) await onDelete();
  }
}

/// Labelled chip row of the feed's access-domain patterns, mirroring the
/// add-feed preview. An empty list means the feed declared no domain
/// restriction.
class _AccessDomains extends StatelessWidget {
  const _AccessDomains({required this.domains});

  final List<String> domains;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.verified_user_outlined,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: LanghuanTheme.spaceSm),
            Text(
              l10n.feedDetailAccessDomains,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: LanghuanTheme.spaceSm),
        if (domains.isEmpty)
          Text(
            l10n.feedDetailNoDomainRestriction,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
          )
        else
          Wrap(
            spacing: LanghuanTheme.spaceSm,
            runSpacing: LanghuanTheme.spaceXs,
            children: [
              for (final domain in domains)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: LanghuanTheme.spaceSm,
                    vertical: LanghuanTheme.spaceXs,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: LanghuanTheme.borderRadiusSm,
                  ),
                  child: Text(
                    domain,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

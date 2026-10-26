import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/utils/errors.dart';
import '../../../shared/utils/snackbars.dart';
import '../../../shared/widgets/loading.dart';
import '../../../src/rust/api/types.dart';
import '../feed_providers.dart';
import '../feed_service.dart';
import 'feed_detail_sheet.dart';
import 'feed_visuals.dart';

/// Card-style feed list item: identity plus live status at a glance.
///
/// The card answers "what is this source and can I use it right now" —
/// name, source meta, pause state, auth state, and load errors. The full
/// metadata and management actions live in the detail sheet (tap the
/// card).
class FeedCard extends ConsumerWidget {
  const FeedCard({
    super.key,
    required this.feed,
    this.isDeleting = false,
    this.borderRadius = LanghuanTheme.borderRadiusMd,
    this.onDelete,
  });

  final FeedMetaItem feed;
  final bool isDeleting;
  final BorderRadius borderRadius;

  /// Handed to the detail sheet so its delete action can hand control
  /// back to the page-level delete flow (confirm dialog + undo).
  final Future<void> Function()? onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final hasError = feed.error != null;
    final authAsync = ref.watch(feedAuthStatusProvider(feed.id));
    // Paused feeds keep their data but step back visually.
    final contentOpacity = feed.enabled ? 1.0 : 0.55;

    return Material(
      color: theme.colorScheme.surfaceContainer,
      borderRadius: borderRadius,
      child: InkWell(
        borderRadius: borderRadius,
        onTap: isDeleting
            ? null
            : () => showFeedDetailSheet(context, feed, onDelete: onDelete),
        child: Padding(
          padding: const EdgeInsets.all(LanghuanTheme.spaceMd),
          child: Row(
            children: [
              // ── Avatar (circle per spec §4.3) ──────────────────────
              Opacity(
                opacity: contentOpacity,
                child: FeedAvatar(feed: feed),
              ),
              const SizedBox(width: LanghuanTheme.spaceMd),

              // ── Text ───────────────────────────────────────────────
              Expanded(
                child: Opacity(
                  opacity: contentOpacity,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        feed.name,
                        style: theme.textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              feed.author != null
                                  ? 'v${feed.version} · ${feed.author}'
                                  : 'v${feed.version}',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (!feed.enabled)
                            Padding(
                              padding: const EdgeInsets.only(
                                left: LanghuanTheme.spaceSm,
                              ),
                              child: FeedStatusChip(label: l10n.feedItemPaused),
                            ),
                          _buildAuthBadge(authAsync, theme),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              // ── Trailing ───────────────────────────────────────────
              if (isDeleting)
                const LanghuanSpinner(size: 20)
              else ...[
                // Pause/resume: paused feeds stay installed and searchable
                // by explicit choice, but leave aggregated search and
                // background update checks.
                _FeedEnabledButton(
                  enabled: feed.enabled,
                  onPressed: () => _handleToggle(context, ref, !feed.enabled),
                  l10n: l10n,
                ),
                if (hasError)
                  Icon(
                    Icons.error_outline,
                    size: 20,
                    color: theme.colorScheme.error,
                    semanticLabel: l10n.feedItemLoadError,
                  )
                else
                  Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant.withAlpha(120),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _handleToggle(
    BuildContext context,
    WidgetRef ref,
    bool value,
  ) async {
    final l10n = AppLocalizations.of(context);
    final error = await ref
        .read(feedListProvider.notifier)
        .setFeedEnabled(feedId: feed.id, enabled: value);
    if (error == null || !context.mounted) return;
    showErrorSnack(
      ScaffoldMessenger.of(context),
      '${l10n.feedToggleError}: ${normalizeErrorMessage(error)}',
    );
  }

  /// Builds a small inline badge showing the feed's auth status.
  Widget _buildAuthBadge(
    AsyncValue<FeedAuthStatusModel?> authAsync,
    ThemeData theme,
  ) {
    return authAsync.when(
      loading: () => Padding(
        padding: const EdgeInsets.only(left: LanghuanTheme.spaceSm),
        child: LanghuanSpinner(
          size: 10,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      error: (_, _) => const SizedBox.shrink(),
      data: (status) => status == null
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.only(left: LanghuanTheme.spaceSm),
              child: FeedAuthBadge(status: status),
            ),
    );
  }
}

class _FeedEnabledButton extends StatelessWidget {
  const _FeedEnabledButton({
    required this.enabled,
    required this.onPressed,
    required this.l10n,
  });

  final bool enabled;
  final VoidCallback onPressed;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tooltip = enabled ? l10n.feedPause : l10n.feedResume;

    return Semantics(
      button: true,
      toggled: enabled,
      label: tooltip,
      excludeSemantics: true,
      child: IconButton.filledTonal(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(enabled ? Icons.pause_rounded : Icons.play_arrow_rounded),
        style: IconButton.styleFrom(
          minimumSize: const Size.square(40),
          maximumSize: const Size.square(40),
          padding: EdgeInsets.zero,
          backgroundColor: enabled
              ? colors.secondaryContainer
              : colors.surfaceContainerHighest,
          foregroundColor: enabled
              ? colors.onSecondaryContainer
              : colors.onSurfaceVariant,
        ),
      ),
    );
  }
}

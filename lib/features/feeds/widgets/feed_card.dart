import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../src/rust/api/types.dart';
import '../feed_providers.dart';
import '../feed_service.dart';
import 'feed_detail_sheet.dart';

/// Card-style feed list item with avatar, name, version, author, and status.
///
/// Avatar uses a 40px **circle** per the Wise design spec §4.3.
class FeedCard extends ConsumerWidget {
  const FeedCard({super.key, required this.feed, this.isDeleting = false});

  final FeedMetaItem feed;
  final bool isDeleting;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final hasError = feed.error != null;
    final authAsync = ref.watch(feedAuthStatusProvider(feed.id));

    return Material(
      color: theme.colorScheme.surfaceContainer,
      borderRadius: LanghuanTheme.borderRadiusMd,
      child: InkWell(
        borderRadius: LanghuanTheme.borderRadiusMd,
        onTap: isDeleting ? null : () => showFeedDetailSheet(context, feed),
        child: Padding(
          padding: const EdgeInsets.all(LanghuanTheme.spaceMd),
          child: Row(
            children: [
              // ── Avatar (circle per spec §4.3) ──────────────────────
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: hasError
                      ? theme.colorScheme.errorContainer
                      : theme.colorScheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  feed.name.isNotEmpty ? feed.name[0].toUpperCase() : '?',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: hasError
                        ? theme.colorScheme.onErrorContainer
                        : theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: LanghuanTheme.spaceMd),

              // ── Text ───────────────────────────────────────────────
              Expanded(
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
                        _buildAuthBadge(authAsync, theme, l10n),
                      ],
                    ),
                  ],
                ),
              ),

              // ── Trailing ───────────────────────────────────────────
              if (isDeleting)
                SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: theme.colorScheme.primary,
                  ),
                )
              else if (hasError)
                Icon(
                  Icons.error_outline,
                  size: 20,
                  color: theme.colorScheme.error,
                )
              else
                Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant.withAlpha(120),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Builds a small inline badge showing the feed's auth status.
  Widget _buildAuthBadge(
    AsyncValue<FeedAuthStatusModel?> authAsync,
    ThemeData theme,
    AppLocalizations l10n,
  ) {
    return authAsync.when(
      loading: () => Padding(
        padding: const EdgeInsets.only(left: LanghuanTheme.spaceSm),
        child: SizedBox(
          width: 10,
          height: 10,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      error: (_, _) => const SizedBox.shrink(),
      data: (status) {
        if (status == null) return const SizedBox.shrink();

        final (label, color, bgColor) = switch (status) {
          FeedAuthStatusModel.loggedIn => (
            l10n.feedAuthStatusLoggedIn,
            theme.colorScheme.onTertiaryContainer,
            theme.colorScheme.tertiaryContainer,
          ),
          FeedAuthStatusModel.expired => (
            l10n.feedAuthStatusExpired,
            theme.colorScheme.onErrorContainer,
            theme.colorScheme.errorContainer,
          ),
          FeedAuthStatusModel.loggedOut => (
            l10n.feedAuthStatusLoggedOut,
            theme.colorScheme.onSurfaceVariant,
            theme.colorScheme.surfaceContainerHighest,
          ),
          FeedAuthStatusModel.unsupported => (
            l10n.feedAuthStatusUnsupported,
            theme.colorScheme.onSurfaceVariant,
            theme.colorScheme.surfaceContainerHighest,
          ),
        };

        return Padding(
          padding: const EdgeInsets.only(left: LanghuanTheme.spaceSm),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: color,
                fontSize: 10,
              ),
            ),
          ),
        );
      },
    );
  }
}

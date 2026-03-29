import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../src/bindings/signals/signals.dart';
import 'feed_detail_sheet.dart';

/// Card-style feed list item with avatar, name, version, author, and status.
///
/// Avatar uses a 40px **circle** per the Wise design spec §4.3.
class FeedCard extends StatelessWidget {
  const FeedCard({super.key, required this.feed, this.isDeleting = false});

  final FeedMetaItem feed;
  final bool isDeleting;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasError = feed.error != null;

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
}

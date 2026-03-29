import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/cover_placeholder.dart';
import '../../feeds/feed_service.dart';

/// Card-style search result with book cover, title, author, and description.
class SearchResultCard extends StatelessWidget {
  const SearchResultCard({super.key, required this.item});

  final SearchResultModel item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.surfaceContainer,
      borderRadius: LanghuanTheme.borderRadiusMd,
      child: InkWell(
        borderRadius: LanghuanTheme.borderRadiusMd,
        onTap: () {
          // TODO: navigate to book detail page
        },
        child: Padding(
          padding: const EdgeInsets.all(LanghuanTheme.spaceMd),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Book cover ─────────────────────────────────────────
              ClipRRect(
                borderRadius: LanghuanTheme.borderRadiusSm,
                child: item.coverUrl != null
                    ? Image.network(
                        item.coverUrl!,
                        width: 48,
                        height: 64,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const CoverPlaceholder(),
                      )
                    : const CoverPlaceholder(),
              ),
              const SizedBox(width: LanghuanTheme.spaceMd),

              // ── Text content ───────────────────────────────────────
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: LanghuanTheme.spaceXs),
                    Text(
                      item.author,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (item.description != null) ...[
                      const SizedBox(height: LanghuanTheme.spaceXs),
                      Text(
                        item.description!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant.withAlpha(
                            180,
                          ),
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),

              // ── Chevron ────────────────────────────────────────────
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onSurfaceVariant.withAlpha(120),
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

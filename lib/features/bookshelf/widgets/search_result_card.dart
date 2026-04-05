import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/cover_image.dart';
import '../../../shared/widgets/cover_placeholder.dart';
import '../../feeds/feed_service.dart';

/// Card-style search result with book cover, title, author, and description.
class SearchResultCard extends StatelessWidget {
  const SearchResultCard({super.key, required this.item, this.onTap});

  final SearchResultModel item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.surfaceContainer,
      borderRadius: LanghuanTheme.borderRadiusMd,
      child: InkWell(
        borderRadius: LanghuanTheme.borderRadiusMd,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(LanghuanTheme.spaceMd),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Book cover ─────────────────────────────────────────
              ClipRRect(
                borderRadius: LanghuanTheme.borderRadiusSm,
                child: SizedBox(
                  width: 48,
                  height: 64,
                  child: item.coverUrl != null
                      ? CoverImage(url: item.coverUrl!, width: 48, height: 64)
                      : const CoverPlaceholder(),
                ),
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

import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/cover_image.dart';
import '../../../shared/widgets/cover_placeholder.dart';
import '../../feeds/feed_service.dart';
import 'book_cover_hero.dart';

/// Card-style search result with book cover, title, author, and description.
class SearchResultCard extends StatelessWidget {
  const SearchResultCard({
    super.key,
    required this.item,
    this.onTap,
    this.coverHeroTag,
    this.titleHeroTag,
    this.authorHeroTag,
  });

  final SearchResultModel item;
  final VoidCallback? onTap;
  final Object? coverHeroTag;
  final Object? titleHeroTag;
  final Object? authorHeroTag;

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
              _optionalCoverHero(
                tag: coverHeroTag,
                child: ClipRRect(
                  borderRadius: LanghuanTheme.borderRadiusSm,
                  child: SizedBox(
                    width: 48,
                    height: 64,
                    child: item.coverUrl != null
                        ? CoverImage(
                            url: item.coverUrl!,
                            width: 48,
                            height: 64,
                            decodeWidth: 120,
                            decodeHeight: 160,
                          )
                        : const CoverPlaceholder(),
                  ),
                ),
              ),
              const SizedBox(width: LanghuanTheme.spaceMd),

              // ── Text content ───────────────────────────────────────
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _optionalTextHero(
                      tag: titleHeroTag,
                      child: Text(
                        item.title,
                        style: theme.textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(height: LanghuanTheme.spaceXs),
                    _optionalTextHero(
                      tag: authorHeroTag,
                      child: Text(
                        item.author,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
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

  Widget _optionalCoverHero({required Object? tag, required Widget child}) {
    return tag == null
        ? child
        : Hero(
            tag: tag,
            flightShuttleBuilder: bookCoverFlightShuttleBuilder,
            child: child,
          );
  }

  Widget _optionalTextHero({required Object? tag, required Widget child}) {
    return tag == null ? child : BookTextHero(tag: tag, child: child);
  }
}

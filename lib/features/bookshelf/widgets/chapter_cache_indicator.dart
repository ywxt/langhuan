import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';

/// Null means the cache state is unknown; never label a failed query uncached.
class ChapterCacheIndicator extends StatelessWidget {
  const ChapterCacheIndicator({
    super.key,
    required this.cached,
    this.foreground,
  });
  final bool? cached;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final stored = cached;
    if (stored == null) return const SizedBox.square(dimension: 18);
    final l = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final label = stored ? l.chapterCached : l.chapterNotCached;
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Icon(
        stored ? Icons.download_done_rounded : Icons.cloud_outlined,
        size: 18,
        color:
            foreground ?? (stored ? colors.primary : colors.onSurfaceVariant),
        semanticLabel: label,
      ),
    );
  }
}

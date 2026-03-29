import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Book-cover placeholder shown when no image is available or the network
/// image fails to load.
///
/// Renders a 48 × 64 container with a subtle background and a book icon.
class CoverPlaceholder extends StatelessWidget {
  const CoverPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: 48,
      height: 64,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: LanghuanTheme.borderRadiusSm,
      ),
      child: Icon(
        Icons.menu_book_outlined,
        size: 24,
        color: theme.colorScheme.onSurfaceVariant.withAlpha(100),
      ),
    );
  }
}

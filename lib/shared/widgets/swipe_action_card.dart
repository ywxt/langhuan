import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Shared swipe-to-delete shell for list cards.
///
/// Domain-specific confirmation and undo behavior stays with the owning page;
/// this widget keeps gesture direction, clipping, and action styling aligned.
class SwipeActionCard extends StatelessWidget {
  const SwipeActionCard({
    super.key,
    required this.dismissKey,
    required this.child,
    required this.confirmDismiss,
    this.enabled = true,
    this.borderRadius = LanghuanTheme.borderRadiusMd,
  });

  final Key dismissKey;
  final Widget child;
  final ConfirmDismissCallback confirmDismiss;
  final bool enabled;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: borderRadius,
      child: Dismissible(
        key: dismissKey,
        direction: enabled
            ? DismissDirection.endToStart
            : DismissDirection.none,
        background: ColoredBox(
          color: colors.errorContainer,
          child: Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: LanghuanTheme.spaceLg,
              ),
              child: Icon(Icons.delete_outline, color: colors.onErrorContainer),
            ),
          ),
        ),
        confirmDismiss: confirmDismiss,
        child: child,
      ),
    );
  }
}

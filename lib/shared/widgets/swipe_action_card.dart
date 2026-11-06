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
    required this.deleteTooltip,
    this.enabled = true,
    this.borderRadius = LanghuanTheme.borderRadiusMd,
  });

  final Key dismissKey;
  final Widget child;
  final ConfirmDismissCallback confirmDismiss;
  final String deleteTooltip;
  final bool enabled;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final desktop = switch (Theme.of(context).platform) {
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => true,
      _ => false,
    };
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
        child: desktop
            ? Material(
                color: colors.surfaceContainer,
                child: Row(
                  children: [
                    Expanded(child: child),
                    IconButton(
                      tooltip: deleteTooltip,
                      color: colors.error,
                      onPressed: enabled
                          ? () => confirmDismiss(DismissDirection.endToStart)
                          : null,
                      icon: const Icon(Icons.delete_outline),
                    ),
                    const SizedBox(width: LanghuanTheme.spaceXs),
                  ],
                ),
              )
            : child,
      ),
    );
  }
}

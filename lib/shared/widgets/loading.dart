import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Canonical spinner per the Wise design spec §5.2.
///
/// A 24px primary-colour circular indicator with a 2px stroke. Sizes of 12px
/// and below use a 1.5px stroke so the arc stays legible.
class LanghuanSpinner extends StatelessWidget {
  const LanghuanSpinner({super.key, this.size = 24, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CircularProgressIndicator(
        strokeWidth: size <= 12 ? 1.5 : 2,
        color: color,
      ),
    );
  }
}

/// Full-page loading placeholder per the Wise design spec §5.2.
///
/// Centres a [LanghuanSpinner] with optional explanatory [label].
class LoadingState extends StatelessWidget {
  const LoadingState({super.key, this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    final spinner = const LanghuanSpinner();
    if (label == null) return Center(child: spinner);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(LanghuanTheme.spaceXl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            spinner,
            const SizedBox(height: LanghuanTheme.spaceMd),
            Text(
              label!,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

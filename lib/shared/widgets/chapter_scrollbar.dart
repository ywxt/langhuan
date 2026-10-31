import 'package:flutter/material.dart';

/// A directory thumb large enough to find and drag on a touch screen.
/// RawScrollbar also expands touch hit testing to a minimum of 48 pixels.
class ChapterScrollbar extends StatelessWidget {
  const ChapterScrollbar({
    super.key,
    required this.controller,
    required this.child,
  });

  final ScrollController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) => RawScrollbar(
    controller: controller,
    thumbVisibility: false,
    trackVisibility: false,
    interactive: true,
    thickness: 12,
    minThumbLength: 64,
    radius: const Radius.circular(6),
    crossAxisMargin: 4,
    mainAxisMargin: 4,
    thumbColor: Theme.of(context).colorScheme.primary.withValues(alpha: .75),
    timeToFade: const Duration(milliseconds: 1400),
    child: ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: child,
    ),
  );
}

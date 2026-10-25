import 'package:flutter/material.dart';

/// Keeps every stateful-shell branch alive while animating between them.
class AnimatedBranchContainer extends StatelessWidget {
  const AnimatedBranchContainer({
    super.key,
    required this.currentIndex,
    required this.children,
  }) : assert(currentIndex >= 0 && currentIndex < children.length);

  final int currentIndex;
  final List<Widget> children;

  static const _duration = Duration(milliseconds: 240);

  @override
  Widget build(BuildContext context) {
    final paintOrder = <int>[
      for (var i = 0; i < children.length; i++)
        if (i != currentIndex) i,
      currentIndex,
    ];

    return Stack(
      fit: StackFit.expand,
      children: [
        for (final index in paintOrder)
          _BranchTransition(
            key: ValueKey(index),
            active: index == currentIndex,
            offset: index < currentIndex ? -0.035 : 0.035,
            duration: _duration,
            child: children[index],
          ),
      ],
    );
  }
}

class _BranchTransition extends StatelessWidget {
  const _BranchTransition({
    super.key,
    required this.active,
    required this.offset,
    required this.duration,
    required this.child,
  });

  final bool active;
  final double offset;
  final Duration duration;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !active,
      child: ExcludeSemantics(
        excluding: !active,
        child: AnimatedSlide(
          duration: duration,
          curve: Curves.easeOutCubic,
          offset: active ? Offset.zero : Offset(offset, 0),
          child: AnimatedOpacity(
            duration: duration,
            curve: Curves.easeOutCubic,
            opacity: active ? 1 : 0,
            child: TickerMode(enabled: active, child: child),
          ),
        ),
      ),
    );
  }
}

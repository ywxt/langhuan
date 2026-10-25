import 'package:flutter/material.dart';

const fadeSlideTransitionDuration = Duration(milliseconds: 300);
const fadeSlideReverseTransitionDuration = Duration(milliseconds: 240);

Widget buildFadeSlideTransition(Animation<double> animation, Widget child) {
  final curvedAnimation = CurvedAnimation(
    parent: animation,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  return FadeTransition(
    opacity: curvedAnimation,
    child: SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, 0.08),
        end: Offset.zero,
      ).animate(curvedAnimation),
      child: child,
    ),
  );
}

/// Fades the page in while sliding it up from below its final position.
///
/// Installed as the app-wide Material default. GoRouter routes also call
/// [buildFadeSlideTransition] explicitly so their animation does not depend on
/// how GoRouter adapts a widget builder into a platform page.
class FadeSlidePageTransitionsBuilder extends PageTransitionsBuilder {
  const FadeSlidePageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return buildFadeSlideTransition(animation, child);
  }

  @override
  Duration get transitionDuration => fadeSlideTransitionDuration;

  @override
  Duration get reverseTransitionDuration => fadeSlideReverseTransitionDuration;
}

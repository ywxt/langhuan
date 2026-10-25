import 'package:flutter/material.dart';

/// Fades the page in while sliding it up from 10% below its final position.
///
/// Installed as the app-wide default through
/// `LanghuanTheme`'s [ThemeData.pageTransitionsTheme], so every pushed route
/// animates consistently without per-route [CustomTransitionPage] wrappers.
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
    return FadeTransition(
      opacity: CurveTween(curve: Curves.easeOut).animate(animation),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.1),
          end: Offset.zero,
        ).chain(CurveTween(curve: Curves.easeOut)).animate(animation),
        child: child,
      ),
    );
  }
}

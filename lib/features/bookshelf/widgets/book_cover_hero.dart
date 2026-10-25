import 'package:flutter/material.dart';

/// Stable Hero tag shared by book lists and the book detail page.
String bookCoverHeroTag(String feedId, String bookId) =>
    'book-cover-$feedId-$bookId';

String bookTitleHeroTag(String feedId, String bookId) =>
    'book-title-$feedId-$bookId';

String bookAuthorHeroTag(String feedId, String bookId) =>
    'book-author-$feedId-$bookId';

class BookTextHero extends StatelessWidget {
  const BookTextHero({super.key, required this.tag, required this.child});

  final Object tag;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Hero(
      tag: tag,
      flightShuttleBuilder: _bookTextFlightShuttleBuilder,
      child: Material(type: MaterialType.transparency, child: child),
    );
  }
}

Widget _bookTextFlightShuttleBuilder(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection flightDirection,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final hero = switch (flightDirection) {
    HeroFlightDirection.push => toHeroContext.widget as Hero,
    HeroFlightDirection.pop => fromHeroContext.widget as Hero,
  };
  return FittedBox(fit: BoxFit.scaleDown, child: hero.child);
}

/// Keeps the already-rendered cover in flight while the destination resolves
/// its locally cached image.
Widget bookCoverFlightShuttleBuilder(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection flightDirection,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  return (fromHeroContext.widget as Hero).child;
}

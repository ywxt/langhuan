import 'package:flutter/material.dart';

/// Stable Hero tag shared by book lists and the book detail page.
String bookCoverHeroTag(String feedId, String bookId) =>
    'book-cover-$feedId-$bookId';

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

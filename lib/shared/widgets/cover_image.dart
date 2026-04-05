import 'dart:io';

import 'package:flutter/material.dart';

import 'cover_placeholder.dart';

/// Displays a book cover image that supports both network URLs and local file
/// paths.
///
/// - If [url] starts with `/` or `file://`, it is treated as a local file and
///   rendered with [Image.file].
/// - Otherwise it is treated as a network URL and rendered with
///   [Image.network].
///
/// A [CoverPlaceholder] is shown underneath with a fade-in animation when the
/// image loads. On error the placeholder is shown instead.
class CoverImage extends StatelessWidget {
  const CoverImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.fadeDuration = const Duration(milliseconds: 220),
    this.fadeCurve = Curves.easeOut,
  });

  /// The image source — either a network URL or a local file path.
  final String url;

  /// Optional fixed width.
  final double? width;

  /// Optional fixed height.
  final double? height;

  /// How the image should be inscribed into the box.
  final BoxFit fit;

  /// Custom placeholder widget. Defaults to [CoverPlaceholder].
  final Widget? placeholder;

  /// Duration of the fade-in animation.
  final Duration fadeDuration;

  /// Curve of the fade-in animation.
  final Curve fadeCurve;

  bool get _isLocalFile => url.startsWith('/') || url.startsWith('file://');

  @override
  Widget build(BuildContext context) {
    final fallback = placeholder ?? const CoverPlaceholder();
    final image = _isLocalFile
        ? _buildFileImage(fallback)
        : _buildNetworkImage(fallback);

    // Use a sized Stack so the image defines the intrinsic size and the
    // placeholder fills behind it.  StackFit.expand would crash when the
    // parent has unbounded constraints (e.g. inside a Column/SliverList).
    return SizedBox(
      width: width,
      height: height,
      child: Stack(fit: StackFit.expand, children: [fallback, image]),
    );
  }

  Widget _buildNetworkImage(Widget fallback) {
    return Image.network(
      url,
      width: width,
      height: height,
      fit: fit,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded) return child;
        return AnimatedOpacity(
          opacity: frame == null ? 0.0 : 1.0,
          duration: fadeDuration,
          curve: fadeCurve,
          child: child,
        );
      },
      errorBuilder: (_, _, _) => fallback,
    );
  }

  Widget _buildFileImage(Widget fallback) {
    final path = url.startsWith('file://') ? url.substring(7) : url;
    final file = File(path);

    if (!file.existsSync()) return fallback;

    return Image.file(
      file,
      width: width,
      height: height,
      fit: fit,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded) return child;
        return AnimatedOpacity(
          opacity: frame == null ? 0.0 : 1.0,
          duration: fadeDuration,
          curve: fadeCurve,
          child: child,
        );
      },
      errorBuilder: (_, _, _) => fallback,
    );
  }
}

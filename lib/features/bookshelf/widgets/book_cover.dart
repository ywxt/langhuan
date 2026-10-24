import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/app_service.dart';
import '../../../shared/widgets/cover_image.dart';
import '../../../shared/widgets/cover_placeholder.dart';

/// Cover bytes stored in the database, keyed by `(feedId, bookId)`.
///
/// Auto-disposing (the riverpod 3 default): cached bytes are dropped when the
/// page stops listening and re-read from the database on the next visit,
/// which is a cheap query.
final coverProvider = FutureProvider.family<Uint8List?, (String, String)>((
  ref,
  key,
) async {
  final (feedId, bookId) = key;
  final cover = await AppService.instance.getCover(
    feedId: feedId,
    bookId: bookId,
  );
  return cover?.bytes;
});

/// Renders a book cover from the bytes stored in the database.
///
/// Falls back to the remote [url] via [CoverImage] while no bytes are stored
/// (download still in flight or failed), and to [placeholder] when neither is
/// available. The fade-in matches [CoverImage] for a seamless look.
class BookCover extends ConsumerWidget {
  const BookCover({
    super.key,
    required this.feedId,
    required this.bookId,
    this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.fadeDuration = const Duration(milliseconds: 220),
  });

  final String feedId;
  final String bookId;

  /// Remote cover URL used as a fallback while the stored bytes are missing.
  final String? url;

  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? placeholder;
  final Duration fadeDuration;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fallback = placeholder ?? const CoverPlaceholder();
    final cover = ref.watch(coverProvider((feedId, bookId)));

    return cover.when(
      data: (bytes) {
        if (bytes != null) {
          return _memoryImage(context, bytes, fallback);
        }
        return _networkFallback(fallback);
      },
      loading: () => fallback,
      error: (_, _) => _networkFallback(fallback),
    );
  }

  Widget _networkFallback(Widget fallback) {
    if (url == null) return fallback;
    return CoverImage(
      url: url!,
      width: width,
      height: height,
      fit: fit,
      placeholder: fallback,
    );
  }

  Widget _memoryImage(BuildContext context, Uint8List bytes, Widget fallback) {
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final cacheW = width != null ? (width! * devicePixelRatio).round() : null;
    final cacheH = height != null ? (height! * devicePixelRatio).round() : null;

    final image = Image.memory(
      bytes,
      width: width,
      height: height,
      cacheWidth: cacheW,
      cacheHeight: cacheH,
      fit: fit,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded) return child;
        return AnimatedOpacity(
          opacity: frame == null ? 0.0 : 1.0,
          duration: fadeDuration,
          curve: Curves.easeOut,
          child: child,
        );
      },
      errorBuilder: (_, _, _) => fallback,
    );

    // Sized Stack so the placeholder fills behind the image, mirroring
    // [CoverImage]; StackFit.expand would crash under unbounded constraints.
    return SizedBox(
      width: width,
      height: height,
      child: Stack(fit: StackFit.expand, children: [fallback, image]),
    );
  }
}

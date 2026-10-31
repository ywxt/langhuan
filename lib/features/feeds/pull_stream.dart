import 'dart:async';

/// Adapt a native pull handle without delaying cancellation behind an
/// in-flight pull. Pausing the Dart subscription also pauses future pulls.
Stream<T> pullStream<S extends Object, T>(
  Future<S> Function() open,
  Future<T?> Function(S handle) next,
  Future<void> Function(S handle) cancel,
) {
  late final StreamController<T> controller;
  S? handle;
  var cancelled = false;
  Completer<void>? resume;
  Future<void>? cancellation;
  Future<void> closeHandle(S value) => cancellation ??= cancel(value);

  Future<void> pump() async {
    try {
      final value = await open();
      handle = value;
      while (!cancelled) {
        if (controller.isPaused) await resume?.future;
        if (cancelled) break;
        final item = await next(value);
        if (cancelled || item == null) break;
        controller.add(item);
      }
    } catch (error, stack) {
      if (!cancelled) controller.addError(error, stack);
    } finally {
      try {
        final value = handle;
        if (value != null) await closeHandle(value);
      } catch (error, stack) {
        if (!cancelled) controller.addError(error, stack);
      }
      await controller.close();
    }
  }

  controller = StreamController<T>(
    sync: true,
    onListen: () => unawaited(pump()),
    onPause: () => resume ??= Completer<void>(),
    onResume: () {
      resume?.complete();
      resume = null;
    },
    onCancel: () async {
      cancelled = true;
      resume?.complete();
      resume = null;
      final value = handle;
      if (value != null) await closeHandle(value);
    },
  );
  return controller.stream;
}

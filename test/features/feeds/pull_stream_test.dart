import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/feeds/pull_stream.dart';

void main() {
  test(
    'cancel reaches the native handle before an in-flight pull completes',
    () async {
      final pending = Completer<int?>();
      final started = Completer<void>();
      var cancelled = false;
      final stream = pullStream(
        () async => Object(),
        (_) {
          started.complete();
          return pending.future;
        },
        (_) async {
          cancelled = true;
          pending.complete(null);
        },
      );
      final subscription = stream.listen(
        (_) => fail('cancelled result delivered'),
      );
      await started.future;
      await subscription.cancel().timeout(const Duration(seconds: 1));
      expect(cancelled, isTrue);
    },
  );

  test('paused subscriptions do not eagerly drain native pages', () async {
    var pulls = 0, cancels = 0;
    final stream = pullStream(() async => Object(), (_) async => ++pulls, (
      _,
    ) async {
      cancels++;
    });
    final iterator = StreamIterator(stream);
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current, 1);
    await Future<void>.delayed(Duration.zero);
    expect(pulls, 1);
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current, 2);
    await iterator.cancel();
    expect(cancels, 1);
  });
}

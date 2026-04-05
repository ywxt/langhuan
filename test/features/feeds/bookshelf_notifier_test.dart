import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/bookshelf_provider.dart';
import 'package:langhuan/rust_init.dart';
import 'package:langhuan/src/bindings/signals/signals.dart';
import 'dart:async';

void main() {
  test('bookshelf provider stays loading while app data bootstraps', () {
    final container = ProviderContainer(
      overrides: [
        appDataDirectorySetProvider.overrideWith((ref) async {
          // Keep bootstrap pending so bookshelf notifier must not schedule load.
          return Completer<AppDataDirectorySet>().future;
        }),
      ],
    );
    addTearDown(container.dispose);

    final state = container.read(bookshelfProvider);
    expect(state.isLoading, isTrue);
    expect(state.hasError, isFalse);
    expect(state.items, isEmpty);
  });

  test('bookshelf provider exposes bootstrap error outcome', () async {
    const bootstrap = AppDataDirectorySet(
      outcome: AppDataDirectoryOutcomeError(message: 'bootstrap failed'),
    );
    final container = ProviderContainer(
      overrides: [
        appDataDirectorySetProvider.overrideWith((ref) async => bootstrap),
      ],
    );
    addTearDown(container.dispose);

    await container.read(appDataDirectorySetProvider.future);

    final state = container.read(bookshelfProvider);
    expect(state.isLoading, isFalse);
    expect(state.hasError, isTrue);
    expect(state.error, 'bootstrap failed');
  });
}

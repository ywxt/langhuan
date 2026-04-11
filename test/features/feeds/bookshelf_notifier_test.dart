import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/bookshelf_provider.dart';
import 'package:langhuan/rust_init.dart';
import 'dart:async';

void main() {
  test('bookshelf provider stays loading while app data bootstraps', () {
    final container = ProviderContainer(
      overrides: [
        appDataDirectorySetProvider.overrideWith((ref) async {
          // Keep bootstrap pending so bookshelf notifier must not schedule load.
          return Completer<AppDataDirectoryResult>().future;
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
    final container = ProviderContainer(
      overrides: [
        appDataDirectorySetProvider.overrideWith((ref) async {
          throw Exception('bootstrap failed');
        }),
      ],
    );
    addTearDown(container.dispose);

    // Force both providers to be active so the error propagates.
    container.listen(appDataDirectorySetProvider, (_, _) {});
    container.listen(bookshelfProvider, (_, _) {});

    // Wait for the error to propagate through the provider graph.
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final state = container.read(bookshelfProvider);
    expect(state.isLoading, isFalse);
    expect(state.hasError, isTrue);
    expect(state.error, isA<BookshelfError>());
    final error = state.error as BookshelfError;
    expect(error.type, BookshelfErrorType.loadFailed);
  });
}

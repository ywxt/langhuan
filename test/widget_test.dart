// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:langhuan/app.dart';
import 'package:langhuan/rust_init.dart';

void main() {
  testWidgets('App renders with bottom navigation', (
    WidgetTester tester,
  ) async {
    // Provide a fake bootstrap result so the app can settle without Rust.
    const fakeBootstrap = AppDataDirectoryResult(feedCount: 0);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDataDirectorySetProvider.overrideWith(
            (ref) async => fakeBootstrap,
          ),
        ],
        child: const LanghuanApp(),
      ),
    );
    await tester.pumpAndSettle();

    // Verify that the bottom navigation bar is present with 3 tabs
    expect(find.text('Bookshelf'), findsWidgets);
    expect(find.text('Feeds'), findsOneWidget);
    expect(find.text('Settings'), findsWidgets);
  });
}

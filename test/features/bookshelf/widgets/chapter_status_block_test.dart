import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/widgets/chapter_status_block.dart';
import 'package:langhuan/l10n/app_localizations.dart';

void main() {
  Widget buildTestApp(Widget child) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );
  }

  testWidgets('renders loading state', (tester) async {
    await tester.pumpWidget(
      buildTestApp(
        const ChapterStatusBlock(
          kind: ChapterStatusBlockKind.loading,
          compact: false,
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Loading…'), findsOneWidget);
  });

  testWidgets('renders error state with retry action and message', (
    tester,
  ) async {
    var tapped = false;

    await tester.pumpWidget(
      buildTestApp(
        ChapterStatusBlock(
          kind: ChapterStatusBlockKind.error,
          title: 'Chapter 2',
          message: 'HTTP request failed',
          onRetry: () async {
            tapped = true;
          },
        ),
      ),
    );

    expect(find.text('Chapter 2'), findsOneWidget);
    expect(find.text('Failed to load chapter'), findsOneWidget);
    expect(find.text('HTTP request failed'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();

    expect(tapped, isTrue);
  });

  testWidgets('shows loading animation immediately after tapping retry', (
    tester,
  ) async {
    final completer = Completer<void>();

    await tester.pumpWidget(
      buildTestApp(
        ChapterStatusBlock(
          kind: ChapterStatusBlockKind.error,
          message: 'HTTP request failed',
          onRetry: () => completer.future,
        ),
      ),
    );

    await tester.tap(find.text('Retry'));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Loading…'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);

    completer.complete();
    await tester.pump();
  });
}

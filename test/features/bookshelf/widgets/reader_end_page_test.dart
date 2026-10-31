import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/widgets/reader_end_page.dart';
import 'package:langhuan/l10n/app_localizations.dart';

Widget _host({
  Future<void> Function()? refresh,
  VoidCallback? back,
  ThemeData? theme,
  double textScale = 1,
}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: theme,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(
    body: ReaderEndPage(onRefresh: refresh, onReturnToText: back ?? () {}),
  ),
);

void main() {
  testWidgets('refresh shows progress, handles an error and can be retried', (
    tester,
  ) async {
    final gate = Completer<void>();
    var calls = 0;
    var returned = false;
    await tester.pumpWidget(
      _host(
        refresh: () {
          calls++;
          return calls == 1 ? gate.future : Future.value();
        },
        back: () => returned = true,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('reader-end-refresh')));
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(find.text('Checking for updates…'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('reader-end-refresh')));
    expect(calls, 1);
    gate.completeError(StateError('network offline'));
    await tester.pumpAndSettle();
    expect(find.textContaining('network offline'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('reader-end-refresh')));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(
      find.text('Contents refreshed. No new chapters yet.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('reader-end-return')));
    expect(returned, isTrue);
  });

  for (final size in [
    const Size(320, 640),
    const Size(640, 240),
    const Size(1200, 800),
  ]) {
    testWidgets('end page fits $size with large text in dark mode', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        _host(theme: ThemeData.dark(), textScale: 2, refresh: () async {}),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('reader-end-refresh')),
      );
      expect(
        find.byKey(const ValueKey('reader-end-refresh')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}

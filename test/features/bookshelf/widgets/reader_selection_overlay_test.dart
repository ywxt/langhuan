import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/widgets/reader_overlays.dart';
import 'package:langhuan/features/bookshelf/widgets/reader_types.dart';
import 'package:langhuan/l10n/app_localizations.dart';
import 'package:langhuan/src/rust/api/types.dart';

void main() {
  for (final scale in [1.0, 3.0]) {
    testWidgets('selection actions fit a small viewport at text scale $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var listening = 0;
      var bookmarks = 0;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                padding: const EdgeInsets.only(top: 24, bottom: 24),
                textScaler: TextScaler.linear(scale),
              ),
              child: Scaffold(
                body: Stack(
                  children: [
                    ReaderSelectionOverlay(
                      selection: ParagraphSelection(
                        chapterId: 'c1',
                        paragraphId: 'p1',
                        paragraph: const ParagraphContent.text(
                          id: ParagraphId(
                            original: OriginalParagraphId.source('p1'),
                            path: [],
                          ),
                          content: 'Long paragraph',
                        ),
                        rect: const Rect.fromLTWH(16, -500, 288, 1800),
                      ),
                      theme: Theme.of(context),
                      l10n: AppLocalizations.of(context),
                      onAddBookmark: () => bookmarks++,
                      onListenFromHere: () => listening++,
                      onComments: () {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final toolbar = tester.getRect(
        find
            .descendant(
              of: find.byType(ReaderSelectionOverlay),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(toolbar.top, greaterThanOrEqualTo(24));
      expect(toolbar.bottom, lessThanOrEqualTo(456));
      expect(toolbar.width, lessThanOrEqualTo(288));
      await tester.tap(find.byTooltip('Listen from here'));
      await tester.tap(find.text('Add Bookmark'));
      expect(listening, 1);
      expect(bookmarks, 1);
      expect(tester.takeException(), isNull);
    });
  }
}

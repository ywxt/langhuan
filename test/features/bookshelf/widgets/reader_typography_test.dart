import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/bookshelf/widgets/paragraph_view.dart';
import 'package:langhuan/features/bookshelf/widgets/reader_typography.dart';
import 'package:langhuan/src/rust/api/types.dart';

void main() {
  // The test fonts do not implement `halt`; these tests pin the style
  // contract (the feature travels with the recipe), not actual squeezing.
  const textTheme = TextTheme(
    bodyLarge: TextStyle(fontSize: 16),
    headlineSmall: TextStyle(fontSize: 24),
  );

  group('ReaderTypography', () {
    test('body scales the theme size and applies the reader line height', () {
      final body = ReaderTypography(
        textTheme: textTheme,
        fontScale: 1.5,
        fontFamily: 'Serif',
        letterSpacing: 0.5,
        lineHeight: 2.0,
      ).body;
      expect(body.fontSize, 24);
      expect(body.fontFamily, 'Serif');
      expect(body.letterSpacing, 0.5);
      expect(body.height, 2.0);
      expect(body.fontFeatures, contains(const FontFeature('halt')));
    });

    test('title scales the theme size without a height override', () {
      final title = ReaderTypography(
        textTheme: textTheme,
        fontScale: 1.5,
        fontFamily: 'Serif',
        letterSpacing: 0.5,
        lineHeight: 2.0,
      ).title;
      expect(title.fontSize, 36);
      expect(title.fontFamily, 'Serif');
      expect(title.letterSpacing, 0.5);
      expect(title.height, isNull);
      expect(title.fontFeatures, contains(const FontFeature('halt')));
    });

    test('defaults keep the theme family and base sizes', () {
      final typo = ReaderTypography(textTheme: textTheme);
      expect(typo.body.fontSize, 16);
      expect(typo.body.fontFamily, isNull);
      expect(typo.body.letterSpacing, 0.0);
      expect(typo.body.height, 1.8);
      expect(typo.title.fontSize, 24);
    });
  });

  testWidgets('ParagraphView renders body text with punctuation squeeze', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Material(child: ParagraphView(paragraph: _text('你好，世界。'))),
      ),
    );
    final body = tester.widget<Text>(find.text('你好，世界。'));
    expect(body.style?.fontFeatures, contains(const FontFeature('halt')));
    expect(body.style?.height, 1.8);
  });

  testWidgets('ParagraphView renders titles with punctuation squeeze', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: Material(child: ParagraphView(paragraph: _title('第一章')))),
    );
    final title = tester.widget<Text>(find.text('第一章'));
    expect(title.style?.fontFeatures, contains(const FontFeature('halt')));
  });
}

ParagraphContent _text(String content) => ParagraphContent_Text(
  id: ParagraphId(original: OriginalParagraphId.source('p1'), path: const []),
  content: content,
);

ParagraphContent _title(String text) => ParagraphContent_Title(
  id: ParagraphId(original: OriginalParagraphId.source('t1'), path: const []),
  text: text,
);

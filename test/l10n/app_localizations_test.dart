import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/l10n/app_localizations.dart';

void main() {
  testWidgets('zh-CN resolves simplified Chinese and interpolates values', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh', 'CN'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            final l = AppLocalizations.of(context);
            return Text('${l.navBookshelf} / ${l.bookshelfNewChapters(3)}');
          },
        ),
      ),
    );
    expect(find.text('书架 / 3 个新章节'), findsOneWidget);
  });

  test('default Chinese retains traditional wording', () async {
    final l = await AppLocalizations.delegate.load(const Locale('zh'));
    expect(l.navBookshelf, '書架');
    expect(l.transformIndentDescription, '移除文字段落開頭的空白，並設置首行縮進。');
  });
}

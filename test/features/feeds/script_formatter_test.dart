import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/feeds/script_formatter.dart';

void main() {
  test('splits top-level statements onto their own lines', () {
    expect(formatJavaScript('let a=1;let b=2;'), 'let a=1;\nlet b=2;');
  });

  test('indents nested blocks and dedents on close', () {
    expect(
      formatJavaScript('function f(){if(a){b();}}'),
      'function f() {\n  if(a) {\n    b();\n  }\n}',
    );
  });

  test('keeps semicolons inside for-parens inline', () {
    expect(
      formatJavaScript('for(let i=0;i<3;i++){}'),
      'for(let i=0;i<3;i++) {\n}',
    );
  });

  test('leaves string contents untouched', () {
    expect(formatJavaScript('let s="a{b;c}";'), 'let s="a{b;c}";');
  });

  test('leaves template literals untouched', () {
    expect(formatJavaScript(r'let t=`x${y}z`;'), r'let t=`x${y}z`;');
  });

  test('leaves regex literals untouched', () {
    expect(formatJavaScript('let re=/[{};]/g;'), 'let re=/[{};]/g;');
  });

  test('treats a slash after a value as division, not a regex', () {
    expect(formatJavaScript('let x=a/b;'), 'let x=a/b;');
  });

  test('treats a slash after a keyword as a regex start', () {
    expect(formatJavaScript('return/re/.test(x);'), 'return/re/.test(x);');
  });

  test('puts each comment on its own line', () {
    expect(
      formatJavaScript('a();// hi\nb();/* there */c();'),
      'a();\n// hi\nb();\n/* there */\nc();',
    );
  });

  test('keeps empty blocks readable', () {
    expect(formatJavaScript('f(){}g();'), 'f() {\n}\ng();');
  });

  test('keeps else chains attached', () {
    expect(
      formatJavaScript('if(a){x();}else{y();}'),
      'if(a) {\n  x();\n} else {\n  y();\n}',
    );
  });

  test('is idempotent on already-formatted scripts', () {
    const script = 'function f() {\n  return 1;\n}\n';
    expect(formatJavaScript(script), 'function f() {\n  return 1;\n}');
  });

  test('handles unterminated strings without swallowing the file', () {
    expect(
      formatJavaScript('let s="oops;{}\nlet a=1;'),
      'let s="oops;{}\nlet a=1;',
    );
  });

  test('empty input stays empty', () {
    expect(formatJavaScript(''), '');
  });
}

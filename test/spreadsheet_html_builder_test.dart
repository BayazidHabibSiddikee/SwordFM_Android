import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/spreadsheet_html_builder.dart';

void main() {
  group('escapeHtml', () {
    test('escapes HTML-significant characters', () {
      expect(escapeHtml('<b>&"</b>'), '&lt;b&gt;&amp;"&lt;/b&gt;');
    });

    test('leaves plain text unchanged', () {
      expect(escapeHtml('Mango 10'), 'Mango 10');
    });
  });

  group('parseCsvRow', () {
    test('splits simple comma-separated cells', () {
      expect(parseCsvRow('a,b,c'), ['a', 'b', 'c']);
    });

    test('keeps commas inside quoted cells', () {
      expect(parseCsvRow('a,"b,c",d'), ['a', 'b,c', 'd']);
    });

    test('trailing comma yields trailing empty cell', () {
      expect(parseCsvRow('a,'), ['a', '']);
    });
  });

  group('buildCsvViewerHtml', () {
    test('renders rows and escapes cell text', () {
      final html = buildCsvViewerHtml('Item,Qty\nMango,10\n<script>,x');
      expect(html, contains('<tr><td>Item</td><td>Qty</td></tr>'));
      expect(html, contains('<tr><td>Mango</td><td>10</td></tr>'));
      // Script-tag cell content must be escaped, not injected raw.
      expect(html, contains('<td>&lt;script&gt;</td>'));
      expect(html, isNot(contains('<script>,x')));
    });

    test('skips blank lines', () {
      final html = buildCsvViewerHtml('a,b\n\n\nc,d');
      expect('<tr>'.allMatches(html).length, 2);
    });
  });

  group('buildSheetJsViewerHtml', () {
    const js = 'var XLSX_MOCK = 1;';
    const b64 = 'aGVsbG8='; // "hello"

    test('inlines the SheetJS source and base64 payload', () {
      final html = buildSheetJsViewerHtml(sheetJsSource: js, base64Bytes: b64);
      expect(html, contains(js));
      expect(html, contains('var B64 = "$b64";'));
    });

    test('contains exactly two script blocks with a render entrypoint', () {
      final html = buildSheetJsViewerHtml(sheetJsSource: js, base64Bytes: b64);
      expect('</script>'.allMatches(html).length, 2);
      expect(html, contains('XLSX.read(data'));
    });

    test('rejects JS containing a literal script-closing tag', () {
      expect(
        () => buildSheetJsViewerHtml(
            sheetJsSource: 'var a = "</script>";', base64Bytes: b64),
        throwsA(isA<AssertionError>()),
      );
    });

    test('bundled SheetJS asset carries no literal script-closing tag', () {
      // Regression for the device-observed blank viewer: a literal
      // "</script" inside the inlined asset would terminate the inline
      // <script> block early, so the render call never runs and the WebView
      // paints nothing. Kept as an explicit expectation (not just a debug
      // assert) so it holds in profile/release-mode test runs too.
      final asset = File('assets/js/xlsx.full.min.js').readAsStringSync();
      expect(asset.contains('</script'), isFalse);
    });
  });
}

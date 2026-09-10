import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/doc_converter.dart';

void main() {
  group('DocConverter non-ASCII (UTF-8) safety', () {
    test('toText preserves CJK + emoji bytes', () async {
      final dir = await Directory.systemTemp.createTemp('swordfm_utf8_');
      try {
        final src = File('${dir.path}/uni.md');
        const content = '# 日本語テスト\n\nCafé naïve façade 🎉✨ 中文测试\n';
        await src.writeAsString(content);
        final out = await DocConverter.toText(src.path);
        expect(out, isNotNull);
        final back = await File(out!).readAsString();
        expect(back, contains('日本語テスト'));
        expect(back, contains('Café'));
        expect(back, contains('🎉'));
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}

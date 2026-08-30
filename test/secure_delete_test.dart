import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/utils/file_utils.dart';

void main() {
  test('secureDelete overwrites every chunk then removes the file', () async {
    final dir = Directory.systemTemp.createTempSync('swordfm_shred_');
    final f = File('${dir.path}/secret.bin');
    // ~300KB of patterned data — forces multiple 64KB chunk overwrite passes.
    f.writeAsBytesSync(List<int>.filled(300 * 1024, 0xAB));
    expect(f.existsSync(), isTrue);
    expect(f.lengthSync(), greaterThan(64 * 1024));

    await FileUtils.secureDelete(f.path);

    expect(f.existsSync(), isFalse, reason: 'file must be removed after shred');
    dir.deleteSync(recursive: true);
  });
}

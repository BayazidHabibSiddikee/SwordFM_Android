import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Installs APK / XAPK packages via the native PackageInstaller channel.
class InstallerService {
  static const _channel = MethodChannel('com.swordfm/installer');

  /// Installs a single [apkPath]. Returns null on success, or an error message.
  static Future<String?> installApk(String apkPath) async {
    try {
      final ok = await _channel.invokeMethod<bool>('installApk', {
        'path': apkPath,
      });
      return ok == true ? null : 'Install failed';
    } on PlatformException catch (e) {
      return e.message ?? 'Install failed';
    } catch (e) {
      return '$e';
    }
  }

  /// Installs an XAPK: unzips it to a temp dir, collects base + split APKs,
  /// and hands them to the native PackageInstaller session. Returns null on
  /// success, or an error message. OBB files are not installed — they must be
  /// placed manually at Android/obb/<package>/ (noted in the returned message
  /// when present).
  static Future<String?> installXapk(String xapkPath) async {
    final File xapk;
    try {
      xapk = File(xapkPath);
      if (!await xapk.exists()) return 'File not found';
    } catch (e) {
      return '$e';
    }
    try {
      final baseDir = await getTemporaryDirectory();
      final outDir = Directory(
        p.join(
          baseDir.path,
          'swordfm_install_${DateTime.now().millisecondsSinceEpoch}',
        ),
      );
      await outDir.create(recursive: true);

      final archive = ZipDecoder().decodeBytes(await xapk.readAsBytes());
      final baseApks = <String>[];
      final splitApks = <String>[];
      final obbs = <String>[];

      for (final f in archive.files) {
        if (!f.isFile) continue;
        final lower = f.name.toLowerCase();
        if (lower.endsWith('.apk')) {
          final outPath = p.join(outDir.path, p.basename(f.name));
          await File(outPath).writeAsBytes(f.content as List<int>);
          if (lower.endsWith('/base.apk') || lower == 'base.apk') {
            baseApks.add(outPath);
          } else {
            splitApks.add(outPath);
          }
        } else if (lower.endsWith('.obb')) {
          obbs.add(p.basename(f.name));
        }
      }

      if (baseApks.isEmpty && splitApks.isNotEmpty) {
        // No base.apk — treat the first APK as the base.
        baseApks.add(splitApks.removeAt(0));
      }
      if (baseApks.isEmpty) return 'No APK found inside the XAPK';

      final ok = await _channel.invokeMethod<bool>('installApks', {
        'paths': [...baseApks, ...splitApks],
      });
      if (ok != true) return 'Install failed';
      if (obbs.isNotEmpty) {
        return 'Installing…\nNote: ${obbs.length} OBB file(s) must be moved to '
            'Android/obb/<package>/ manually';
      }
      return null;
    } catch (e) {
      return '$e';
    }
  }
}

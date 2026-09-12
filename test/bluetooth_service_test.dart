// Tests for BluetoothShareService protocol helpers and filename-handling logic.
//
// These tests do NOT require a real Bluetooth device or platform channel.
// They cover:
//   - Transfer-complete message format (contract spec)
//   - BluetoothDeviceItem.fromMap parsing edge cases
//   - BluetoothTransferProgress percentage computation
//   - Protocol frame metadata-length guard values
//   - Filename sanitisation for the bt_send/ cache (onActivityResult logic)
//   - SHA-256 hex digest format validation

import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/bluetooth_share_service.dart';

// ---------------------------------------------------------------------------
// Mirror of _buildTransferCompleteMessage logic (same contract, tests only)
// ---------------------------------------------------------------------------
String _buildMsg(String savedPath, String sha256, bool verified) {
  var msg = savedPath.isEmpty
      ? 'Transfer Complete!'
      : 'Transfer Complete! Saved to $savedPath';
  if (sha256.isNotEmpty) {
    msg += '\nSHA-256: $sha256';
    msg += verified ? ' (verified)' : ' (not verified)';
  }
  return msg;
}

// ---------------------------------------------------------------------------
// Mirror of onActivityResult filename-strip logic (Kotlin: File(name).name)
// ---------------------------------------------------------------------------
String _stripToBasename(String raw) {
  final stripped = raw.split('/').last.split('\\').last;
  return stripped.isEmpty ? 'bt_file' : stripped;
}

// ---------------------------------------------------------------------------
// Mirror of native metadata-length guard
// ---------------------------------------------------------------------------
bool _isValidMetadataLength(int length) =>
    length > 0 && length <= 1024 * 1024;

void main() {
  // -------------------------------------------------------------------------
  // Transfer-complete message format
  // -------------------------------------------------------------------------
  group('transfer-complete message format', () {
    test('no path, no hash — returns "Transfer Complete!"', () {
      expect(_buildMsg('', '', false), 'Transfer Complete!');
    });

    test('with path — includes "Saved to <path>"', () {
      final msg = _buildMsg('/sdcard/SwordFM/file.pdf', '', false);
      expect(msg, contains('Saved to /sdcard/SwordFM/file.pdf'));
    });

    test('with sha256 and verified=true — shows "(verified)"', () {
      final sha = 'a' * 64;
      final msg = _buildMsg('', sha, true);
      expect(msg, contains('SHA-256: $sha'));
      expect(msg, contains('(verified)'));
      expect(msg, isNot(contains('(not verified)')));
    });

    test('with sha256 and verified=false — shows "(not verified)"', () {
      final sha = 'b' * 64;
      final msg = _buildMsg('', sha, false);
      expect(msg, contains('SHA-256: $sha'));
      expect(msg, contains('(not verified)'));
    });

    test('empty sha256 — no SHA-256 line emitted', () {
      final msg = _buildMsg('/some/path', '', false);
      expect(msg, isNot(contains('SHA-256')));
    });

    test('SHA-256 can be extracted by [0-9a-f]{64} regex', () {
      final sha = 'deadbeef' * 8; // 64 hex chars
      final msg = _buildMsg('', sha, true);
      final match = RegExp(r'\b[0-9a-f]{64}\b').firstMatch(msg);
      expect(match?.group(0), sha);
    });

    test('regex returns null when message has no hash', () {
      final msg = _buildMsg('', '', false);
      final match = RegExp(r'\b[0-9a-f]{64}\b').firstMatch(msg);
      expect(match, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // BluetoothDeviceItem.fromMap
  // -------------------------------------------------------------------------
  group('BluetoothDeviceItem.fromMap', () {
    test('parses name and address from valid map', () {
      final item = BluetoothDeviceItem.fromMap({
        'name': 'Pixel 7',
        'address': 'AA:BB:CC:DD:EE:FF',
      });
      expect(item.name, 'Pixel 7');
      expect(item.address, 'AA:BB:CC:DD:EE:FF');
    });

    test('falls back to "Unknown" when name key is absent', () {
      final item = BluetoothDeviceItem.fromMap({'address': '11:22:33:44:55:66'});
      expect(item.name, 'Unknown');
    });

    test('falls back to empty string when address key is absent', () {
      final item = BluetoothDeviceItem.fromMap({'name': 'Test Device'});
      expect(item.address, '');
    });

    test('handles empty map without throwing', () {
      final item = BluetoothDeviceItem.fromMap({});
      expect(item.name, 'Unknown');
      expect(item.address, '');
    });

    test('null values fall back gracefully', () {
      final item = BluetoothDeviceItem.fromMap({'name': null, 'address': null});
      expect(item.name, 'Unknown');
      expect(item.address, '');
    });
  });

  // -------------------------------------------------------------------------
  // BluetoothTransferProgress percentage
  // -------------------------------------------------------------------------
  group('BluetoothTransferProgress.percentage', () {
    test('is 0.0 when totalBytes is 0 (no division by zero)', () {
      final p = BluetoothTransferProgress(
        filename: 'test.zip',
        bytesTransferred: 0,
        totalBytes: 0,
        isSending: true,
      );
      expect(p.percentage, 0.0);
    });

    test('is 1.0 when transfer is complete', () {
      final p = BluetoothTransferProgress(
        filename: 'done.pdf',
        bytesTransferred: 1024,
        totalBytes: 1024,
        isSending: false,
      );
      expect(p.percentage, 1.0);
    });

    test('is 0.5 at the halfway point', () {
      final p = BluetoothTransferProgress(
        filename: 'half.mp3',
        bytesTransferred: 500,
        totalBytes: 1000,
        isSending: true,
      );
      expect(p.percentage, closeTo(0.5, 0.0001));
    });

    test('isSending flag is preserved', () {
      final p = BluetoothTransferProgress(
        filename: 'f',
        bytesTransferred: 0,
        totalBytes: 10,
        isSending: false,
      );
      expect(p.isSending, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // Protocol frame: metadata length guard
  // Native: if (metadataLength <= 0 || metadataLength > 1024*1024) → throw
  // -------------------------------------------------------------------------
  group('protocol metadata-length guard', () {
    test('0 is invalid', () => expect(_isValidMetadataLength(0), isFalse));
    test('-1 is invalid', () => expect(_isValidMetadataLength(-1), isFalse));
    test('1 is valid', () => expect(_isValidMetadataLength(1), isTrue));
    test('120 bytes is valid (typical JSON frame)', () {
      expect(_isValidMetadataLength(120), isTrue);
    });
    test('1 MB exactly is valid (boundary)', () {
      expect(_isValidMetadataLength(1024 * 1024), isTrue);
    });
    test('1 MB + 1 is invalid (above boundary)', () {
      expect(_isValidMetadataLength(1024 * 1024 + 1), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // Filename sanitisation (onActivityResult bt_send/ cache)
  // Rule: strip directory components so a crafted URI can't escape the cache.
  // Mirrors Kotlin: File(fileName).name.ifBlank { "bt_file" }
  // -------------------------------------------------------------------------
  group('filename sanitisation for bt_send cache', () {
    test('plain filename passes unchanged', () {
      expect(_stripToBasename('document.pdf'), 'document.pdf');
    });

    test('forward-slash path → basename only', () {
      expect(_stripToBasename('/Downloads/secret.txt'), 'secret.txt');
    });

    test('path-traversal with backslash → basename only', () {
      expect(_stripToBasename('..\\..\\etc\\passwd'), 'passwd');
    });

    test('dot-dot with forward slash → basename only', () {
      expect(_stripToBasename('../../etc/shadow'), 'shadow');
    });

    test('empty string → "bt_file" fallback', () {
      expect(_stripToBasename(''), 'bt_file');
    });

    test('only slashes → "bt_file" fallback', () {
      expect(_stripToBasename('/////'), 'bt_file');
    });

    test('filename with spaces is preserved', () {
      expect(_stripToBasename('my file name.mp4'), 'my file name.mp4');
    });

    test('filename with unicode is preserved', () {
      expect(_stripToBasename('音楽.mp3'), '音楽.mp3');
    });
  });

  // -------------------------------------------------------------------------
  // SHA-256 hex digest format
  // -------------------------------------------------------------------------
  group('SHA-256 hex digest format validation', () {
    test('64 lowercase hex chars is valid', () {
      final hex = 'a1b2c3d4' * 8;
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(hex), isTrue);
    });

    test('uppercase hex does NOT match lowercase-only pattern', () {
      final hex = 'A1B2C3D4' * 8;
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(hex), isFalse);
    });

    test('63 chars is too short', () {
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch('a' * 63), isFalse);
    });

    test('65 chars is too long', () {
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch('a' * 65), isFalse);
    });

    test('empty string is invalid', () {
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(''), isFalse);
    });

    test('all-zeros is a valid format (edge case)', () {
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch('0' * 64), isTrue);
    });
  });
}

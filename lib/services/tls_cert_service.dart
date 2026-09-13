import 'dart:io';
import 'dart:math';
import 'package:basic_utils/basic_utils.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
// RSAPrivateKey / RSAPublicKey arrive via basic_utils' pointycastle re-export.

/// Self-signed TLS identity for the LAN share server.
///
/// Browsers will show a trust warning for a self-signed cert on first
/// connect — that is expected and documented in the LAN screen: the PIN
/// still gates every endpoint, TLS only adds transport privacy against
/// passive LAN eavesdroppers. The cert persists in the app support dir so
/// clients see a stable fingerprint across restarts (no re-warning).
///
/// Generated lazily on first TLS enable (RSA-2048 takes ~1 s); afterwards
/// the PEM files are reused. Validity is 825 days (mirroring browser-trusted
/// lifetime caps) with the server IP + `SwordFM.local` as SANs.
class TlsCertService {
  static const _certFile = 'swordfm_share_cert.pem';
  static const _keyFile = 'swordfm_share_key.pem';
  static const _validityDays = 825;

  /// Returns a [SecurityContext] backed by the persisted (or newly generated)
  /// self-signed cert. Throws on generation failure — callers fall back to
  /// plain HTTP.
  static Future<SecurityContext> contextForIp(String ip) async {
    final dir = await getApplicationSupportDirectory();
    final certPath = p.join(dir.path, _certFile);
    final keyPath = p.join(dir.path, _keyFile);
    final certFile = File(certPath);
    final keyFile = File(keyPath);

    if (!await certFile.exists() || !await keyFile.exists()) {
      await _generate(ip, certPath, keyPath);
    }
    final context = SecurityContext();
    context.useCertificateChain(certPath);
    context.usePrivateKey(keyPath);
    return context;
  }

  /// SHA-256 fingerprint of the persisted cert (`AA:BB:…`), shown in the LAN
  /// screen so users can verify they're talking to their own server.
  /// Returns null when no cert exists yet.
  static Future<String?> fingerprint() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final certFile = File(p.join(dir.path, _certFile));
      if (!await certFile.exists()) return null;
      final cert = X509Utils.x509CertificateFromPem(
        await certFile.readAsString(),
      );
      return cert.sha256Thumbprint;
    } catch (_) {
      return null;
    }
  }

  /// Deletes the persisted identity so the next TLS start generates fresh.
  static Future<void> rotate() async {
    try {
      final dir = await getApplicationSupportDirectory();
      await File(p.join(dir.path, _certFile)).delete();
      await File(p.join(dir.path, _keyFile)).delete();
    } catch (_) {}
  }

  static Future<void> _generate(
    String ip,
    String certPath,
    String keyPath,
  ) async {
    final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
    final privateKey = pair.privateKey as RSAPrivateKey;
    final publicKey = pair.publicKey as RSAPublicKey;

    final dn = {
      'CN': 'SwordFM LAN Share',
      'O': 'SwordFM',
    };
    final csr = X509Utils.generateRsaCsrPem(dn, privateKey, publicKey);
    final serial = _randomSerial();
    final certPem = X509Utils.generateSelfSignedCertificate(
      privateKey,
      csr,
      _validityDays,
      serialNumber: serial,
      sans: [ip, 'SwordFM.local'],
    );
    final keyPem = CryptoUtils.encodeRSAPrivateKeyToPem(privateKey);

    await File(certPath).writeAsString(certPem);
    await File(keyPath).writeAsString(keyPem);
  }

  static String _randomSerial() {
    final r = Random.secure();
    // 64-bit positive serial — collision chance across regenerations is nil.
    final hi = r.nextInt(1 << 31);
    final lo = r.nextInt(1 << 31);
    return '${(hi << 31) + lo}';
  }
}

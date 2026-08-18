import 'package:permission_handler/permission_handler.dart';

/// Handles runtime Bluetooth permissions for Android 12+ (API 31+).
///
/// All Bluetooth operations must await [ensurePermissions] before calling
/// any channel methods in [BluetoothShareService].
///
/// Permission mapping:
///   BLUETOOTH_SCAN      → android.permission.BLUETOOTH_SCAN
///   BLUETOOTH_CONNECT   → android.permission.BLUETOOTH_CONNECT
///   BLUETOOTH_ADVERTISE → android.permission.BLUETOOTH_ADVERTISE
///
/// Note: BLUETOOTH_ADVERTISE is requested here because the server-side
/// listener (accepting an inbound RFCOMM connection) needs it. The
/// discoverability *UI toggle* itself is intentionally deferred for v1 —
/// see plan.md. We rely on OS-level pairing instead.
class BtPermissions {
  /// Requests all required BT permissions and returns true if granted.
  static Future<bool> ensurePermissions() async {
    // Check whether the device is on Android 12+; older devices only need
    // the legacy BLUETOOTH / BLUETOOTH_ADMIN which are granted at install.
    final scanStatus = await Permission.bluetoothScan.request();
    final connectStatus = await Permission.bluetoothConnect.request();
    final advertiseStatus = await Permission.bluetoothAdvertise.request();
    return scanStatus.isGranted &&
        connectStatus.isGranted &&
        advertiseStatus.isGranted;
  }

  /// Returns whether all Bluetooth permissions are currently granted.
  static Future<bool> areGranted() async {
    final scan = await Permission.bluetoothScan.status;
    final connect = await Permission.bluetoothConnect.status;
    final advertise = await Permission.bluetoothAdvertise.status;
    return scan.isGranted && connect.isGranted && advertise.isGranted;
  }

  /// Requests each permission individually and reports which are granted.
  static Future<Map<Permission, PermissionStatus>> requestAll() async {
    return {
      Permission.bluetoothScan: await Permission.bluetoothScan.request(),
      Permission.bluetoothConnect: await Permission.bluetoothConnect.request(),
      Permission.bluetoothAdvertise: await Permission.bluetoothAdvertise.request(),
    };
  }

  /// Opens the system settings so the user can grant BT permissions manually.
  static Future<void> openSettings() async => openAppSettings();

  /// Human-readable reason to show the user when permissions are denied.
  static String denialMessage(String perm, PermissionStatus status) {
    if (status.isPermanentlyDenied) {
      return '$perm was permanently denied. Please enable it in Settings.';
    }
    return '$perm was denied. Please allow it to use Bluetooth sharing.';
  }
}

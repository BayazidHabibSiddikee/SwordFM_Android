import 'dart:io';

/// Per-interface health verdict mapped from the interface-health counter table
/// (CRC/input errors, rx/tx drops, collisions, link state).
enum InterfaceHealth { healthy, warning, critical, down }

/// Facts read from `/sys/class/net/<iface>/` (link state, carrier, speed).
typedef SysfsInfo = ({bool up, bool carrier, int? speedMbps});

/// A single network interface snapshot from `/proc/net/dev` + sysfs.
class InterfaceSnapshot {
  final String name;
  final bool linkUp;
  final bool carrier;
  final int? speedMbps;
  final int rxBytes, rxPackets, rxErrors, rxDrops, rxFrame;
  final int txBytes, txPackets, txErrors, txDrops, txCollisions, txCarrier;
  final InterfaceHealth health;
  final List<String> findings;

  const InterfaceSnapshot({
    required this.name,
    required this.linkUp,
    required this.carrier,
    this.speedMbps,
    this.rxBytes = 0,
    this.rxPackets = 0,
    this.rxErrors = 0,
    this.rxDrops = 0,
    this.rxFrame = 0,
    this.txBytes = 0,
    this.txPackets = 0,
    this.txErrors = 0,
    this.txDrops = 0,
    this.txCollisions = 0,
    this.txCarrier = 0,
    required this.health,
    this.findings = const [],
  });

  bool get isLoopback => name == 'lo';

  /// Health from a single cumulative sample (no trend available yet).
  InterfaceHealth get selfHealth {
    if (!linkUp) return InterfaceHealth.down;
    if (rxErrors > 200 || rxFrame > 50 || txCarrier > 50) {
      return InterfaceHealth.critical;
    }
    if (rxErrors > 0 || rxFrame > 0 || txCollisions > 0 ||
        txErrors > 0 || txDrops > 0) {
      return InterfaceHealth.warning;
    }
    return InterfaceHealth.healthy;
  }
}

/// baseline (trend) subtraction result. Cumulative counters only matter by how
/// much they grew over a window, so flags are derived from the deltas.
class InterfaceDiff {
  final InterfaceHealth health;
  final List<String> findings;
  final int rxErrorsDelta, rxDropsDelta, rxPacketsDelta, rxFrameDelta;
  final int txErrorsDelta, txDropsDelta, txCollisionsDelta, txCarrierDelta;
  final int rxBytesDelta, txBytesDelta;

  const InterfaceDiff({
    required this.health,
    required this.findings,
    this.rxErrorsDelta = 0,
    this.rxDropsDelta = 0,
    this.rxPacketsDelta = 0,
    this.rxFrameDelta = 0,
    this.txErrorsDelta = 0,
    this.txDropsDelta = 0,
    this.txCollisionsDelta = 0,
    this.txCarrierDelta = 0,
    this.rxBytesDelta = 0,
    this.txBytesDelta = 0,
  });

  bool get clean => health == InterfaceHealth.healthy && findings.isEmpty;
}
/// Ties the counter-table logic together: computes a trend verdict from two
/// snapshots of the same interface.
InterfaceDiff computeDiff(InterfaceSnapshot before, InterfaceSnapshot after) {
  final findings = <String>[];
  var health = InterfaceHealth.healthy;

  final dRxE = after.rxErrors - before.rxErrors;
  final dRxF = after.rxFrame - before.rxFrame;
  final dTxC = after.txCarrier - before.txCarrier;
  final dTxE = after.txErrors - before.txErrors;
  final dTxCol = after.txCollisions - before.txCollisions;
  final dRxD = after.rxDrops - before.rxDrops;
  final dRxP = after.rxPackets - before.rxPackets;

  if (!after.linkUp) {
    health = InterfaceHealth.down;
    findings.add('Link went down');
  } else if (dRxE > 0 || dRxF > 0 || dTxC > 0) {
    health = dRxE > 100 ? InterfaceHealth.critical : InterfaceHealth.warning;
    if (dRxE > 0) findings.add('$dRxE new rx errors (CRC/bad frames)');
    if (dRxF > 0) findings.add('$dRxF new runt/MAC frame errors');
    findings.add('Check cable/optic and both ends of the link');
  }
  if (dTxCol > 0) {
    health = InterfaceHealth.warning;
    findings.add('$dTxCol new TX collisions — duplex mismatch?');
  }
  if (dTxE > 0) {
    health = InterfaceHealth.warning;
    findings.add('$dTxE new TX errors (driver/queue)');
  }
  if (dRxD > 0 && dRxP > 0 && (dRxD / dRxP) > 0.01) {
    health = InterfaceHealth.warning;
    findings.add(
        '$dRxD rx drops (${((dRxD / dRxP) * 100).toStringAsFixed(1)}% of rx) — ingress pressure');
  }

  return InterfaceDiff(
    health: health,
    findings: findings,
    rxErrorsDelta: dRxE,
    rxDropsDelta: dRxD,
    rxPacketsDelta: dRxP,
    rxFrameDelta: dRxF,
    txErrorsDelta: dTxE,
    txDropsDelta: after.txDrops - before.txDrops,
    txCollisionsDelta: dTxCol,
    txCarrierDelta: dTxC,
    rxBytesDelta: after.rxBytes - before.rxBytes,
    txBytesDelta: after.txBytes - before.txBytes,
  );
}

/// Parses raw `/proc/net/dev` text into snapshots (link-state patched by caller).
List<InterfaceSnapshot> parseProcNet(String raw,
    {Map<String, SysfsInfo> sysfs = const {}}) {
  final out = <InterfaceSnapshot>[];
  for (final line in raw.split('\n')) {
    final m = RegExp(r'^\s*([^:\s]+):\s+(.*)$').firstMatch(line);
    if (m == null) continue;
    final name = m.group(1)!;
    final nums = m
        .group(2)!
        .trim()
        .split(RegExp(r'\s+'))
        .map((s) => int.tryParse(s) ?? 0)
        .toList();
    if (nums.length < 16) continue;
    // rx: bytes packets errs drop fifo frame compressed multicast
    // tx: bytes packets errs drop fifo colls carrier compressed
    final f = sysfs[name] ?? (up: true, carrier: true, speedMbps: null);
    out.add(InterfaceSnapshot(
      name: name,
      linkUp: f.up,
      carrier: f.carrier,
      speedMbps: f.speedMbps,
      rxBytes: nums[0],
      rxPackets: nums[1],
      rxErrors: nums[2],
      rxDrops: nums[3],
      rxFrame: nums[5],
      txBytes: nums[8],
      txPackets: nums[9],
      txErrors: nums[10],
      txDrops: nums[11],
      txCollisions: nums[13],
      txCarrier: nums[14],
      health: InterfaceHealth.healthy,
    ));
  }
  return out;
}

/// Reads `/sys/class/net/<name>/` facts (link-up, carrier, speed Mbps).
SysfsInfo readSysfs(String name) {
  bool up = true, carrier = true;
  int? speedMbps;
  try {
    final o = File('/sys/class/net/$name/operstate').readAsStringSync().trim();
    up = o == 'up' || o == 'unknown';
  } catch (_) {}
  try {
    carrier = File('/sys/class/net/$name/carrier').readAsStringSync().trim() == '1';
  } catch (_) {}
  try {
    final sp = int.tryParse(
        File('/sys/class/net/$name/speed').readAsStringSync().trim());
    if (sp != null && sp > 0) speedMbps = sp;
  } catch (_) {}
  return (up: up, carrier: carrier, speedMbps: speedMbps);
}

/// Live capture of all interfaces on this host. Graceful when proc/sysfs are
/// not readable (e.g. sandboxed Android builds).
List<InterfaceSnapshot> captureInterfaces() {
  String raw;
  try {
    raw = File('/proc/net/dev').readAsStringSync();
  } catch (_) {
    return const [];
  }
  final sysfs = <String, SysfsInfo>{};
  return parseProcNet(raw, sysfs: sysfs);
}
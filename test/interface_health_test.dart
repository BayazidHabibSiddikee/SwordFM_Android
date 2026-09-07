// Tests for the interface-health service: parser, single-sample health, and the
// baseline→delta trend logic (the "trend matters more than absolute counter"
// principle from the network-interface-health workflow).
import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/interface_health_service.dart';

const String _proc = '''
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 120456   1234    0    0    0     0          0         0    123456   1234      0    0    0    0      0        0
 wlan0: 1000000   10000   3    2    0     1          0         0    700000   9000      0    1    0    2      1        0
eth0:      0       0      0    0    0     0          0         0       0       0      0    0    0    0      0        0
''';

InterfaceSnapshot _wlan0({
  int rxErrors = 3,
  int rxDrops = 2,
  int rxFrame = 1,
  int txErrors = 0,
  int txDrops = 5,
  int txCollisions = 2,
  int txCarrier = 1,
  int rxPackets = 10000,
}) {
  return InterfaceSnapshot(
    name: 'wlan0',
    linkUp: true,
    carrier: true,
    rxPackets: rxPackets,
    rxErrors: rxErrors,
    rxDrops: rxDrops,
    rxFrame: rxFrame,
    txPackets: 9000,
    txErrors: txErrors,
    txDrops: txDrops,
    txCollisions: txCollisions,
    txCarrier: txCarrier,
    health: InterfaceHealth.healthy,
  );
}

void main() {
  group('parseProcNet', () {
    test('parses interface counters correctly', () {
      final ifaces = parseProcNet(_proc);
      expect(ifaces.length, 3);

      final lo = ifaces.firstWhere((i) => i.name == 'lo');
      expect(lo.rxBytes, 120456);
      expect(lo.rxErrors, 0);

      final wlan = ifaces.firstWhere((i) => i.name == 'wlan0');
      expect(wlan.rxErrors, 3);
      expect(wlan.rxDrops, 2);
      expect(wlan.rxFrame, 1);
      expect(wlan.txCollisions, 2);
      expect(wlan.txCarrier, 1);
    });

    test('applies sysfs link state + speed when provided', () {
      final ifaces = parseProcNet(
        _proc,
        sysfs: {
          'wlan0': (up: true, carrier: true, speedMbps: 866),
          'eth0': (up: false, carrier: false, speedMbps: null),
        },
      );
      final wlan = ifaces.firstWhere((i) => i.name == 'wlan0');
      expect(wlan.speedMbps, 866);
      expect(wlan.linkUp, isTrue);

      final eth = ifaces.firstWhere((i) => i.name == 'eth0');
      expect(eth.linkUp, isFalse);
      expect(eth.carrier, isFalse);
    });
  });

  group('selfHealth (single sample)', () {
    test('clean interface is healthy', () {
      final lo = parseProcNet(_proc).firstWhere((i) => i.name == 'lo');
      expect(lo.selfHealth, InterfaceHealth.healthy);
    });

    test('erroring interface is flagged', () {
      final wlan = parseProcNet(_proc).firstWhere((i) => i.name == 'wlan0');
      expect(wlan.selfHealth, InterfaceHealth.warning);
    });

    test('down interface is down', () {
      final eth = parseProcNet(
        _proc,
        sysfs: {'eth0': (up: false, carrier: false, speedMbps: null)},
      ).firstWhere((i) => i.name == 'eth0');
      expect(eth.selfHealth, InterfaceHealth.down);
    });
  });

  group('computeDiff (trend)', () {
    test('no growth over the window -> clean', () {
      final d = computeDiff(_wlan0(), _wlan0()); // identical counters
      expect(d.clean, isTrue);
      expect(d.health, InterfaceHealth.healthy);
    });

    test('new rx errors -> warning + cable guidance', () {
      final before = _wlan0(rxErrors: 3);
      final after = _wlan0(rxErrors: 6); // +3 new rx errors
      final d = computeDiff(before, after);
      expect(d.rxErrorsDelta, 3);
      expect(d.health, InterfaceHealth.warning);
      expect(
        d.findings.any((f) => f.contains('rx errors')),
        isTrue,
        reason: 'should flag new rx errors',
      );
    });

    group('live host (integration)', () {
    test('captureInterfaces reads real /proc/net/dev and finds lo', () {
      final ifaces = captureInterfaces();
      // On the Linux CI/dev host this should succeed; if proc is masked in a
      // sandbox it returns [] and we skip rather than fail.
      if (ifaces.isEmpty) {
        markTestSkipped('no /proc/net/dev access in this environment');
        return;
      }
      expect(
        ifaces.any((i) => i.name == 'lo'),
        isTrue,
        reason: 'loopback should always be present on a Linux host',
      );
      for (final i in ifaces) {
        expect(i.rxPackets, greaterThanOrEqualTo(0));
        expect(i.txPackets, greaterThanOrEqualTo(0));
        expect(i.rxErrors, greaterThanOrEqualTo(0));
      }
    });
  });
  });
}
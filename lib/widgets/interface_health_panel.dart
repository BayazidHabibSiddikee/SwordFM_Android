import 'dart:async';
import 'package:flutter/material.dart';
import '../services/interface_health_service.dart';
import '../theme/theme.dart';

/// Collapsible panel that surfaces live interface health (link state, speed,
/// rx/tx errors, drops, collisions) on the Network screen. Supports a
/// baseline→delta "Measure over N s" trend view, per the interface-health
/// workflow: cumulative counters only matter by how much they grow.
class InterfaceHealthPanel extends StatefulWidget {
  const InterfaceHealthPanel({super.key, this.expandedByDefault = true});

  final bool expandedByDefault;

  @override
  State<InterfaceHealthPanel> createState() => _InterfaceHealthPanelState();
}

class _InterfaceHealthPanelState extends State<InterfaceHealthPanel> {
  List<InterfaceSnapshot> _ifaces = const [];
  bool _loading = true;
  String? _error;
  late bool _expanded;

  // Trend measurement state.
  bool _measuring = false;
  Map<String, InterfaceSnapshot>? _baseline;
  List<InterfaceDiff>? _diffs;

  @override
  void initState() {
    super.initState();
    _expanded = widget.expandedByDefault;
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
      _diffs = null;
      _baseline = null;
    });
    try {
      final ifaces = captureInterfaces();
      if (ifaces.isEmpty) {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = 'No interface counters available on this device';
          });
        }
        return;
      }
      if (mounted) setState(() => _ifaces = ifaces);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not read interface health: $e';
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Captures a baseline, waits [seconds], captures again, and shows the
  /// per-interface deltas (the trend evidence).
  Future<void> _measure(int seconds) async {
    if (_measuring) return;
    setState(() {
      _measuring = true;
      _baseline = {
        for (final i in _ifaces) i.name: i,
      };
      _diffs = null;
    });
    await Future<void>.delayed(Duration(seconds: seconds));
    final after = captureInterfaces();
    final byName = {for (final i in after) i.name: i};
    final diffs = <InterfaceDiff>[];
    for (final entry in _baseline!.entries) {
      final b = entry.value;
      final a = byName[entry.key];
      if (a == null) continue;
      diffs.add(computeDiff(b, a));
    }
    if (mounted) {
      setState(() {
        _measuring = false;
        _diffs = diffs;
        _ifaces = after;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: OneDarkColors.bgDark,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Column(
        children: [
          _header(cs),
          if (_expanded) _body(cs),
        ],
      ),
    );
  }

  Widget _header(ColorScheme cs) {
    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.settings_ethernet, color: OneDarkColors.cyan, size: 20),
            const SizedBox(width: 8),
            Text(
              'Interface Health',
              style: TextStyle(
                color: OneDarkColors.fg,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
            const SizedBox(width: 8),
            if (!_loading && _error == null) _summaryChip(),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.refresh, size: 18),
              color: OneDarkColors.fgDim,
              tooltip: 'Refresh',
              onPressed: _measuring ? null : _refresh,
            ),
            IconButton(
              icon: const Icon(Icons.timeline, size: 18),
              color: OneDarkColors.fgDim,
              tooltip: 'Measure over 5 s',
              onPressed: _measuring ? null : () => _measure(5),
            ),
            AnimatedRotation(
              turns: _expanded ? 0 : -0.25,
              duration: const Duration(milliseconds: 150),
              child: Icon(Icons.expand_more, color: OneDarkColors.fgDim),
            ),
          ],
        ),
      ),
    );
  }
Widget _summaryChip() {
    final total = _ifaces.length;
    final down = _ifaces.where((i) => !i.linkUp).length;
    final warn = _ifaces
        .where((i) => i.linkUp && i.selfHealth != InterfaceHealth.healthy)
        .length;
    final color = down > 0
        ? OneDarkColors.red
        : warn > 0
            ? OneDarkColors.amber
            : OneDarkColors.green;
    final label = down > 0
        ? '$down down'
        : warn > 0
            ? '$warn flagged'
            : '$total ok';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _body(ColorScheme cs) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.info_outline, color: OneDarkColors.fgDim, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _error!,
                style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_measuring)
          const LinearProgressIndicator(minHeight: 2),
        for (final i in _ifaces) _ifaceTile(i, cs),
        if (_diffs != null) ...[
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Text(
              'Trend over last measurement',
              style: TextStyle(
                color: OneDarkColors.cyan,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          for (var k = 0; k < _ifaces.length && k < _diffs!.length; k++)
            _diffTile(_ifaces[k].name, _diffs![k], cs),
        ],
      ],
    );
  }

  Widget _ifaceTile(InterfaceSnapshot i, ColorScheme cs) {
    final health = i.selfHealth;
    final color = _healthColor(health);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Icon(_healthIcon(health), color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  i.name,
                  style: TextStyle(
                    color: OneDarkColors.fg,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                Text(
                  _subtitle(i),
                  style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11),
                ),
              ],
            ),
          ),
          Text(
            _healthLabel(health),
            style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _diffTile(String name, InterfaceDiff d, ColorScheme cs) {
    final color = _healthColor(d.health);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Icon(_healthIcon(d.health), color: color, size: 16),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(color: OneDarkColors.fg, fontSize: 12),
                ),
                if (d.findings.isNotEmpty)
                  ...d.findings.map(
                    (f) => Text(
                      '• $f',
                      style: TextStyle(
                        color: d.clean ? OneDarkColors.fgDim : color,
                        fontSize: 11,
                      ),
                    ),
                  )
                else
                  Text(
                    'No new errors over the window',
                    style: TextStyle(color: OneDarkColors.green, fontSize: 11),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _subtitle(InterfaceSnapshot i) {
    final parts = <String>[
      i.linkUp ? 'link up' : 'link down',
    ];
    if (i.speedMbps != null) parts.add('${i.speedMbps} Mbps');
    if (!i.isLoopback) {
      parts.add('rx err ${i.rxErrors} · drop ${i.rxDrops}');
      parts.add('tx err ${i.txErrors} · coll ${i.txCollisions}');
    }
    return parts.join('  ·  ');
  }

  Color _healthColor(InterfaceHealth h) => switch (h) {
        InterfaceHealth.healthy => OneDarkColors.green,
        InterfaceHealth.warning => OneDarkColors.amber,
        InterfaceHealth.critical => OneDarkColors.red,
        InterfaceHealth.down => OneDarkColors.red,
      };

  IconData _healthIcon(InterfaceHealth h) => switch (h) {
        InterfaceHealth.healthy => Icons.check_circle,
        InterfaceHealth.warning => Icons.warning_amber_rounded,
        InterfaceHealth.critical => Icons.error,
        InterfaceHealth.down => Icons.link_off,
      };

  String _healthLabel(InterfaceHealth h) => switch (h) {
        InterfaceHealth.healthy => 'OK',
        InterfaceHealth.warning => 'WARN',
        InterfaceHealth.critical => 'CRIT',
        InterfaceHealth.down => 'DOWN',
      };
}
}
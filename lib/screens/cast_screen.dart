import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/theme.dart';

/// Cast screen — discover and connect to Chromecast / DLNA devices.
/// Uses Android MediaRouter via MethodChannel.
class CastScreen extends StatefulWidget {
  const CastScreen({super.key});
  @override
  State<CastScreen> createState() => _CastScreenState();
}

class _CastScreenState extends State<CastScreen> {
  static const _channel = MethodChannel('com.swordfm/cast');
  bool _scanning = true;
  List<Map<String, dynamic>> _devices = [];
  String? _connectedDevice;
  String? _error;

  @override
  void initState() {
    super.initState();
    _discover();
  }

  Future<void> _discover() async {
    setState(() {
      _scanning = true;
      _error = null;
      _devices = [];
    });
    try {
      final result = await _channel.invokeMethod<List>('discoverDevices');
      if (result != null) {
        _devices = result.cast<Map<String, dynamic>>();
      }
    } on PlatformException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _connect(String deviceId) async {
    try {
      await _channel.invokeMethod('connect', {'deviceId': deviceId});
      setState(() => _connectedDevice = deviceId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connect failed: $e'), backgroundColor: OneDarkColors.red),
        );
      }
    }
  }

  Future<void> _disconnect() async {
    try {
      await _channel.invokeMethod('disconnect');
      setState(() => _connectedDevice = null);
    } catch (_) {}
  }

  // ignore: unused_element
  Future<void> _castUrl(String url) async {
    if (_connectedDevice == null) return;
    try {
      await _channel.invokeMethod('castUrl', {'url': url, 'deviceId': _connectedDevice});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cast failed: $e'), backgroundColor: OneDarkColors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OneDarkColors.bg,
      appBar: AppBar(
        title: const Text('Cast', style: TextStyle(fontSize: 16)),
        backgroundColor: OneDarkColors.bgDark,
        foregroundColor: OneDarkColors.fg,
        iconTheme: IconThemeData(color: OneDarkColors.fg),
        actions: [
          if (_connectedDevice != null)
            IconButton(
              icon: Icon(Icons.stop_circle, color: OneDarkColors.red),
              tooltip: 'Disconnect',
              onPressed: _disconnect,
            ),
          IconButton(
            icon: Icon(Icons.refresh, color: OneDarkColors.fgDim),
            tooltip: 'Refresh',
            onPressed: _discover,
          ),
        ],
      ),
      body: _scanning
          ? Center(child: CircularProgressIndicator(color: OneDarkColors.cyan))
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.error_outline, size: 48, color: OneDarkColors.red),
                      const SizedBox(height: 12),
                      Text(_error!, style: TextStyle(color: OneDarkColors.fgDim), textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _discover,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : _devices.isEmpty
                  ? _buildEmptyState()
                  : _buildDeviceList(),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cast, size: 64, color: OneDarkColors.fgDim),
          const SizedBox(height: 16),
          Text('No devices found', style: TextStyle(color: OneDarkColors.fg, fontSize: 16)),
          const SizedBox(height: 8),
          Text(
            'Make sure your Chromecast or DLNA device\nis on the same Wi-Fi network.',
            style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _discover,
            icon: const Icon(Icons.refresh),
            label: const Text('Scan Again'),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceList() {
    return Column(
      children: [
        if (_connectedDevice != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: OneDarkColors.green.withValues(alpha: 0.1),
            child: Row(
              children: [
                Icon(Icons.cast_connected, size: 18, color: OneDarkColors.green),
                const SizedBox(width: 8),
                Text(
                  'Connected to ${_connectedDevice!}',
                  style: TextStyle(color: OneDarkColors.green, fontSize: 12),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: _devices.length,
            separatorBuilder: (_, i) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final device = _devices[i];
              final id = device['id'] ?? 'Unknown';
              final name = device['name'] ?? id;
              final isConn = _connectedDevice == id;
              return ListTile(
                leading: Icon(
                  Icons.tv,
                  size: 24,
                  color: isConn ? OneDarkColors.green : OneDarkColors.cyan,
                ),
                title: Text(name, style: TextStyle(color: OneDarkColors.fg)),
                subtitle: Text(id, style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11)),
                trailing: isConn
                    ? Icon(Icons.check_circle, color: OneDarkColors.green)
                    : Icon(Icons.chevron_right, color: OneDarkColors.fgDim),
                onTap: isConn ? null : () => _connect(id),
              );
            },
          ),
        ),
      ],
    );
  }
}

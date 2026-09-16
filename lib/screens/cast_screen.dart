import 'dart:async';
import 'package:flutter/material.dart';
import '../services/dlna_cast_service.dart';
import '../theme/theme.dart';

/// Cast screen — discover DLNA/UPnP renderers on the LAN (smart TVs, Kodi,
/// VLC, DLNA speakers) and push media URLs to them.
///
/// Pure-Dart SSDP + SOAP via [DlnaCastService] — no Cast SDK, no native
/// code. Chromecast (proprietary protocol) is explicitly out of scope and
/// the empty state says so.
class CastScreen extends StatefulWidget {
  /// Optional media URL to offer for casting (e.g. opened from the LAN
  /// share screen). When null the screen only discovers renderers.
  final String? initialUrl;
  const CastScreen({super.key, this.initialUrl});

  @override
  State<CastScreen> createState() => _CastScreenState();
}

class _CastScreenState extends State<CastScreen> {
  bool _scanning = true;
  List<DlnaDevice> _devices = [];
  DlnaDevice? _selected;
  String? _error;
  String? _casting;
  final _urlController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _urlController.text = widget.initialUrl ?? '';
    _discover();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _discover() async {
    setState(() {
      _scanning = true;
      _error = null;
      _devices = [];
    });
    try {
      final found = await DlnaCastService.discover().timeout(
        const Duration(seconds: 12),
      );
      if (!mounted) return;
      setState(() {
        _devices = found;
        // Keep the selection if the device is still around.
        if (_selected != null &&
            !_devices.any((d) => d.id == _selected!.id)) {
          _selected = null;
        }
      });
    } on TimeoutException {
      if (mounted) {
        setState(
          () => _error = 'Discovery timed out — is Wi-Fi connected?',
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _cast() async {
    final device = _selected;
    final url = _urlController.text.trim();
    if (device == null || url.isEmpty || _casting != null) return;
    setState(() => _casting = url);
    try {
      await DlnaCastService.castUrl(device, url);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Casting to ${device.name}'),
          backgroundColor: OneDarkColors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Cast failed: $e'),
          backgroundColor: OneDarkColors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _casting = null);
    }
  }

  Future<void> _stop() async {
    final device = _selected;
    if (device == null) return;
    try {
      await DlnaCastService.stop(device);
    } catch (_) {}
    if (mounted) setState(() => _selected = null);
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
          if (_selected != null)
            IconButton(
              icon: Icon(Icons.stop_circle, color: OneDarkColors.red),
              tooltip: 'Stop & disconnect',
              onPressed: _stop,
            ),
          IconButton(
            icon: Icon(Icons.refresh, color: OneDarkColors.fgDim),
            tooltip: 'Refresh',
            onPressed: _discover,
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            color: OneDarkColors.bgDark,
            child: Row(
              children: [
                Icon(Icons.cast_connected, color: OneDarkColors.cyan, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Cast media to a DLNA/UPnP Smart TV. Ensure your TV and phone are on the same Wi-Fi network. '
                    'You can also cast local files directly from the Files tab using the "Cast" action in the context menu.',
                    style: TextStyle(color: OneDarkColors.fgDim, fontSize: 13, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          // ── URL bar ──────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlController,
                    style: TextStyle(color: OneDarkColors.fg, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Media URL to cast (http…)',
                      hintStyle: TextStyle(color: OneDarkColors.fgDim),
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    onSubmitted: (_) => _cast(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _selected != null &&
                          _urlController.text.trim().isNotEmpty &&
                          _casting == null
                      ? _cast
                      : null,
                  icon: _casting != null
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cast, size: 18),
                  label: const Text('Cast'),
                ),
              ],
            ),
          ),
          if (_selected != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: OneDarkColors.green.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.cast_connected,
                    size: 18,
                    color: OneDarkColors.green,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Target: ${_selected!.name}',
                      style: TextStyle(
                        color: OneDarkColors.green,
                        fontSize: 12,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _scanning
                ? Center(
                    child: CircularProgressIndicator(
                      color: OneDarkColors.cyan,
                    ),
                  )
                : _error != null
                    ? _buildError()
                    : _devices.isEmpty
                        ? _buildEmptyState()
                        : _buildDeviceList(),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 48, color: OneDarkColors.red),
          const SizedBox(height: 12),
          Text(
            _error!,
            style: TextStyle(color: OneDarkColors.fgDim),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _discover,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cast, size: 64, color: OneDarkColors.fgDim),
            const SizedBox(height: 16),
            Text(
              'No DLNA renderers found',
              style: TextStyle(color: OneDarkColors.fg, fontSize: 16),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'SwordFM discovers DLNA/UPnP renderers (smart TVs, Kodi, '
              'VLC, network speakers) on your Wi-Fi. Chromecast is not '
              'supported — it needs Google\'s proprietary SDK.\n\n'
              'Make sure the renderer and this phone share the same network.',
              style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceList() {
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: _devices.length,
      separatorBuilder: (_, i) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final device = _devices[i];
        final isSel = _selected?.id == device.id;
        return ListTile(
          leading: Icon(
            Icons.tv,
            size: 24,
            color: isSel ? OneDarkColors.green : OneDarkColors.cyan,
          ),
          title: Text(device.name, style: TextStyle(color: OneDarkColors.fg)),
          subtitle: Text(
            device.address.address,
            style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11),
          ),
          trailing: isSel
              ? Icon(Icons.check_circle, color: OneDarkColors.green)
              : Icon(Icons.chevron_right, color: OneDarkColors.fgDim),
          onTap: () => setState(
            () => _selected = isSel ? null : device,
          ),
        );
      },
    );
  }
}

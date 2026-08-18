import 'dart:async';
import 'package:flutter/material.dart';
import '../services/network_service.dart';
import '../theme/theme.dart';

/// Network connections screen — manage WebDAV/SFTP profiles and browse remote files.
class NetworkScreen extends StatefulWidget {
  const NetworkScreen({super.key});

  @override
  State<NetworkScreen> createState() => _NetworkScreenState();
}

class _NetworkScreenState extends State<NetworkScreen> {
  final _service = NetworkService();
  final List<_ProfileEntry> _profiles = [];
  bool _loading = false;
  String? _error;
  String? _currentProfileId;
  List<RemoteEntry> _remoteEntries = [];
  final _logController = StreamController<List<ConnLog>>.broadcast();

  @override
  void initState() {
    super.initState();
    _service.logStream.listen((List<ConnLog> logs) {
      if (mounted) _logController.add(logs);
    });
    // Load persisted profiles on startup
    _service.loadProfiles().then((_) {
      if (mounted) {
        setState(() {
          _profiles.clear();
          for (final p in _service.profiles.values) {
            _profiles.add(_ProfileEntry(p));
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _logController.close();
    super.dispose();
  }

  void _addProfile() {
    showDialog(
      context: context,
      builder: (_) => _AddProfileDialog(
        onSaved: (p) async {
          await _service.addProfile(p);
          if (mounted) setState(() => _profiles.add(_ProfileEntry(p)));
        },
      ),
    );
  }

  Future<void> _removeProfile(String id) async {
    await _service.removeProfile(id);
    if (mounted) {
      setState(() {
        _profiles.removeWhere((e) => e.profile.id == id);
        if (_currentProfileId == id) {
          _currentProfileId = null;
          _remoteEntries = [];
        }
      });
    }
  }

  Future<void> _connect(String profileId) async {
    setState(() {
      _loading = true;
      _error = null;
      _currentProfileId = profileId;
    });
    try {
      final entries = await _service.listDirectory(profileId, path: '/');
      if (mounted) {
        setState(() {
          _remoteEntries = entries;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OneDarkColors.bg,
      appBar: AppBar(
        title: const Text('Network Connections', style: TextStyle(color: OneDarkColors.fg)),
        backgroundColor: OneDarkColors.bgDark,
        foregroundColor: OneDarkColors.fg,
        iconTheme: const IconThemeData(color: OneDarkColors.fg),
        actions: [
          IconButton(icon: const Icon(Icons.add), onPressed: _addProfile, tooltip: 'Add Profile'),
        ],
      ),
      body: Row(
        children: [
          // Left: profile list
          SizedBox(
            width: 260,
            child: Card(
              color: OneDarkColors.bgDark,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text('Profiles', style: TextStyle(color: OneDarkColors.cyan, fontWeight: FontWeight.w600)),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: _profiles.isEmpty
                        ? Center(child: Text('No profiles', style: TextStyle(color: OneDarkColors.fgDim)))
                        : ListView.separated(
                            itemCount: _profiles.length,
                            separatorBuilder: (_, __) => const Divider(height: 1),
                            itemBuilder: (context, i) {
                              final profile = _profiles[i];
                              final isActive = _currentProfileId == profile.profile.id;
                              return ListTile(
                                leading: Icon(
                                  profile.profile.type == 'webdav' ? Icons.cloud : Icons.storage,
                                  color: isActive ? OneDarkColors.cyan : OneDarkColors.fgDim,
                                ),
                                title: Text(profile.profile.name, style: TextStyle(color: isActive ? OneDarkColors.cyan : OneDarkColors.fg)),
                                subtitle: Text('${profile.profile.host}:${profile.profile.port}', style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 11)),
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete, size: 18),
                                  color: OneDarkColors.red,
                                  onPressed: () => _removeProfile(profile.profile.id),
                                ),
                                onTap: () => _connect(profile.profile.id),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
          const VerticalDivider(width: 1),
          // Right: remote file view or log
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(child: Text(_error!, style: const TextStyle(color: OneDarkColors.red)))
                    : _currentProfileId == null
                        ? const Center(child: Text('Select a profile to connect', style: TextStyle(color: OneDarkColors.fgDim)))
                        : _RemoteFileView(profileId: _currentProfileId!, entries: _remoteEntries),
          ),
        ],
      ),
    );
  }
}

class _ProfileEntry {
  final NetworkProfile profile;
  const _ProfileEntry(this.profile);
}

class _AddProfileDialog extends StatefulWidget {
  final Function(NetworkProfile) onSaved;
  const _AddProfileDialog({required this.onSaved});

  @override
  State<_AddProfileDialog> createState() => _AddProfileDialogState();
}

class _AddProfileDialogState extends State<_AddProfileDialog> {
  final _form = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '80');
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  String _type = 'webdav';

  @override
  void dispose() {
    _nameCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: OneDarkColors.bg,
      title: const Text('Add Connection', style: TextStyle(color: OneDarkColors.fg)),
      content: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                value: _type,
                decoration: const InputDecoration(labelText: 'Type', border: OutlineInputBorder()),
                style: const TextStyle(color: OneDarkColors.fg),
                items: const [
                  DropdownMenuItem(value: 'webdav', child: Text('WebDAV')),
                  DropdownMenuItem(value: 'sftp', child: Text('SFTP')),
                ],
                onChanged: (v) => setState(() => _type = v!),
              ),
              const SizedBox(height: 8),
              TextFormField(controller: _nameCtrl, decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder()), style: const TextStyle(color: OneDarkColors.fg)),
              const SizedBox(height: 8),
              TextFormField(controller: _hostCtrl, decoration: const InputDecoration(labelText: 'Host', border: OutlineInputBorder()), style: const TextStyle(color: OneDarkColors.fg)),
              const SizedBox(height: 8),
              TextFormField(controller: _portCtrl, decoration: const InputDecoration(labelText: 'Port', border: OutlineInputBorder()), style: const TextStyle(color: OneDarkColors.fg), keyboardType: TextInputType.number),
              const SizedBox(height: 8),
              TextFormField(controller: _userCtrl, decoration: const InputDecoration(labelText: 'Username', border: OutlineInputBorder()), style: const TextStyle(color: OneDarkColors.fg)),
              const SizedBox(height: 8),
              TextFormField(controller: _passCtrl, decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()), obscureText: true, style: const TextStyle(color: OneDarkColors.fg)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (_form.currentState!.validate() && mounted) {
              final profile = NetworkProfile(
                id: DateTime.now().millisecondsSinceEpoch.toString(),
                name: _nameCtrl.text,
                type: _type,
                host: _hostCtrl.text,
                port: int.tryParse(_portCtrl.text) ?? 80,
                username: _userCtrl.text,
                password: _passCtrl.text,
              );
              widget.onSaved(profile);
              Navigator.pop(context);
            }
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Remote file browser for an active profile connection.
class _RemoteFileView extends StatelessWidget {
  final String profileId;
  final List<RemoteEntry> entries;
  const _RemoteFileView({required this.profileId, required this.entries});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.all(8),
      itemCount: entries.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final e = entries[i];
        return ListTile(
          leading: Icon(e.isDir ? Icons.folder : Icons.insert_drive_file, color: e.isDir ? OneDarkColors.amber : OneDarkColors.fg),
          title: Text(e.name, style: const TextStyle(color: OneDarkColors.fg)),
          subtitle: Text(e.isDir ? 'Folder' : 'File', style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 11)),
        );
      },
    );
  }
}

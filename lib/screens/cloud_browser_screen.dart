import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import '../theme/theme.dart';
import '../services/google_drive_service.dart';
import '../services/dropbox_service.dart';
import '../services/opendrive_service.dart';

enum CloudProvider { googleDrive, dropbox, openDrive }

/// Unified cloud browser screen for Google Drive and Dropbox.
class CloudBrowserScreen extends StatefulWidget {
  const CloudBrowserScreen({super.key});

  @override
  State<CloudBrowserScreen> createState() => _CloudBrowserScreenState();
}

class _CloudBrowserScreenState extends State<CloudBrowserScreen> {
  CloudProvider _currentProvider = CloudProvider.googleDrive;
  final GoogleDriveService _gDrive = GoogleDriveService();
  final DropboxService _dropbox = DropboxService();
  final OpenDriveService _openDrive = OpenDriveService();

  List<CloudFile> _files = [];
  bool _loading = false;
  bool _uploading = false;
  String? _error;
  String _currentPath = '/';
  bool _selectMode = false;
  Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _loadConfigs();
  }

  Future<void> _loadConfigs() async {
    await _gDrive.loadConfig();
    await _dropbox.loadConfig();
    await _openDrive.loadConfig();

    // Auto-connect if credentials exist
    if (_gDrive.savedClientId != null) {
      await _gDrive.connect();
    }
    if (_dropbox.savedAppKey != null) {
      await _dropbox.connect();
    }
    if (_openDrive.savedApiKey != null) {
      await _openDrive.connect();
    }

    if (mounted) {
      setState(() {});
      if (_isConnected) {
        _listFiles();
      }
    }
  }

  bool get _isConnected =>
      (_currentProvider == CloudProvider.googleDrive && _gDrive.isConnected) ||
      (_currentProvider == CloudProvider.dropbox && _dropbox.isConnected) ||
      (_currentProvider == CloudProvider.openDrive && _openDrive.isConnected);

  Future<void> _listFiles() async {
    if (!_isConnected) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      List<CloudFile> files;
      if (_currentProvider == CloudProvider.googleDrive) {
        String? folderId;
        if (_currentPath != '/') {
          folderId = await _gDrive.getFolderIdFromPath(_currentPath);
        }
        files = await _gDrive.listFolder(folderId: folderId);
      } else if (_currentProvider == CloudProvider.dropbox) {
        files = await _dropbox.listFolder(path: _currentPath);
      } else {
        files = await _openDrive.listFolder();
      }

      if (mounted) {
        setState(() {
          _files = files;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  void _navigateToFolder(CloudFile folder) {
    final newPath = _currentProvider == CloudProvider.googleDrive
        ? '$_currentPath${folder.name}/'
        : '$_currentPath${folder.name}';
    setState(() {
      _currentPath = newPath;
      _selectedIds.clear();
    });
    _listFiles();
  }

  void _navigateUp() {
    if (_currentPath == '/') return;
    // Google Drive paths look like /Folder/Sub/; Dropbox paths look like /Folder/Sub.
    String normalized;
    if (_currentProvider == CloudProvider.googleDrive) {
      final parts = _currentPath.split('/').where((p) => p.isNotEmpty).toList();
      if (parts.length <= 1) {
        setState(() {
          _currentPath = '/';
          _selectedIds.clear();
        });
        _listFiles();
        return;
      }
      parts.removeLast();
      normalized = parts.isEmpty ? '/' : '/${parts.join('/')}/';
    } else {
      final idx = _currentPath.lastIndexOf('/');
      normalized = idx == 0 ? '/' : _currentPath.substring(0, idx);
      if (!normalized.endsWith('/')) normalized += '/';
      if (normalized == '//') normalized = '/';
    }
    setState(() {
      _currentPath = normalized;
      _selectedIds.clear();
    });
    _listFiles();
  }

  void _navigateToPath(String path) {
    setState(() {
      _currentPath = path;
      _selectedIds.clear();
    });
    _listFiles();
  }

  Future<void> _connectGoogleDrive() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: OneDarkColors.bgDark,
        title: Text('Google Drive Client ID', style: TextStyle(color: OneDarkColors.fg)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Enter your Google Cloud OAuth 2.0 Client ID.',
              style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
            ),
            const SizedBox(height: 4),
            Text(
              'Create one at console.cloud.google.com → APIs → Credentials',
              style: TextStyle(color: OneDarkColors.cyan, fontSize: 11),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              style: TextStyle(color: OneDarkColors.fg),
              decoration: InputDecoration(
                hintText: 'xxxx.apps.googleusercontent.com',
                hintStyle: TextStyle(color: OneDarkColors.fgDim),
                filled: true,
                fillColor: OneDarkColors.bgDark,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: OneDarkColors.dim),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: OneDarkColors.fgDim)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text('Connect', style: TextStyle(color: OneDarkColors.cyan)),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      await _gDrive.saveClientId(result);
      final success = await _gDrive.connect(clientId: result);
      if (mounted) {
        setState(() {});
        if (success) {
          _listFiles();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Connected to Google Drive')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Couldn\'t connect to Google Drive — check your internet')),
          );
        }
      }
    }
  }

  Future<void> _connectDropbox() async {
    final keyController = TextEditingController();
    final secretController = TextEditingController();
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: OneDarkColors.bgDark,
        title: Text('Dropbox API Credentials', style: TextStyle(color: OneDarkColors.fg)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Enter your Dropbox App Key and Secret.',
              style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
            ),
            const SizedBox(height: 4),
            Text(
              'Create an app at dropbox.com/developers',
              style: TextStyle(color: OneDarkColors.cyan, fontSize: 11),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: keyController,
              style: TextStyle(color: OneDarkColors.fg),
              decoration: InputDecoration(
                labelText: 'App Key',
                labelStyle: TextStyle(color: OneDarkColors.fgDim),
                filled: true,
                fillColor: OneDarkColors.bgDark,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: OneDarkColors.dim),
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: secretController,
              style: TextStyle(color: OneDarkColors.fg),
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'App Secret',
                labelStyle: TextStyle(color: OneDarkColors.fgDim),
                filled: true,
                fillColor: OneDarkColors.bgDark,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: OneDarkColors.dim),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: OneDarkColors.fgDim)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, {
              'key': keyController.text.trim(),
              'secret': secretController.text.trim(),
            }),
            child: Text('Connect', style: TextStyle(color: OneDarkColors.cyan)),
          ),
        ],
      ),
    );

    if (result != null && result['key']!.isNotEmpty) {
      await _dropbox.saveConfig(appKey: result['key']!, appSecret: result['secret']!);
      final success = await _dropbox.connect();
      if (mounted) {
        setState(() {});
        if (success) {
          _listFiles();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Connected to Dropbox')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Couldn\'t connect to Dropbox — check your internet')),
          );
        }
      }
    }
  }

  Future<void> _connectOpenDrive() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: OneDarkColors.bgDark,
        title: Text('OpenDrive API Key', style: TextStyle(color: OneDarkColors.fg)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Enter your OpenDrive API Key.',
              style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
            ),
            const SizedBox(height: 4),
            Text(
              'Get your key at dev.openrazer.com',
              style: TextStyle(color: OneDarkColors.cyan, fontSize: 11),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              style: TextStyle(color: OneDarkColors.fg),
              decoration: InputDecoration(
                hintText: 'Enter API key',
                hintStyle: TextStyle(color: OneDarkColors.fgDim),
                filled: true,
                fillColor: OneDarkColors.bgDark,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: OneDarkColors.dim),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: OneDarkColors.fgDim)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text('Connect', style: TextStyle(color: OneDarkColors.cyan)),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      await _openDrive.saveApiKey(result);
      final success = await _openDrive.connect(apiKey: result);
      if (mounted) {
        setState(() {});
        if (success) {
          _listFiles();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Connected to OpenDrive')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Couldn\'t connect to OpenDrive — check your internet')),
          );
        }
      }
    }
  }

  Future<void> _uploadFile() async {
    final results = await FilePicker.pickFiles(
      type: FileType.any,
      allowMultiple: false,
    );
    if (results.isEmpty || results.single.path == null) return;

    setState(() => _uploading = true);
    try {
      final filePath = results.single.path!;
      final fileName = results.single.name;
      final fileBytes = await File(filePath).readAsBytes();
      bool ok = false;
      if (_currentProvider == CloudProvider.googleDrive) {
        final uploaded = await _gDrive.uploadBytes(fileBytes, fileName);
        ok = uploaded != null;
      } else if (_currentProvider == CloudProvider.dropbox) {
        final remotePath = _currentPath == '/' ? '/$fileName' : '$_currentPath$fileName';
        ok = await _dropbox.uploadFile(fileBytes, remotePath) != null;
      } else {
        ok = await _openDrive.uploadFile(filePath, fileName) != null;
      }
      if (mounted) {
        setState(() => _uploading = false);
        if (ok) {
          _listFiles();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Uploaded $fileName')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Upload didn\'t go through — please retry')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _uploading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: const Text('Upload didn't go through — please retry')),
        );
      }
    }
  }

  Future<void> _createFolder() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: OneDarkColors.bgDark,
        title: Text('New Folder', style: TextStyle(color: OneDarkColors.fg)),
        content: TextField(
          controller: controller,
          style: TextStyle(color: OneDarkColors.fg),
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Folder name',
            hintStyle: TextStyle(color: OneDarkColors.fgDim),
            filled: true,
            fillColor: OneDarkColors.bgDark,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: OneDarkColors.dim),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: OneDarkColors.fgDim)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text('Create', style: TextStyle(color: OneDarkColors.cyan)),
          ),
        ],
      ),
    );

    if (name != null && name.isNotEmpty) {
      if (_currentProvider == CloudProvider.googleDrive) {
        final parentId = _currentPath == '/'
            ? 'root'
            : await _gDrive.getFolderIdFromPath(_currentPath);
        await _gDrive.createFolder(name, parentFolderId: parentId);
      } else {
        await _dropbox.createFolder(name, parentPath: _currentPath);
      }
      _listFiles();
    }
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: OneDarkColors.bgDark,
        title: Text('Delete ${_selectedIds.length} items?', style: TextStyle(color: OneDarkColors.fg)),
        content: Text(
          'This action cannot be undone.',
          style: TextStyle(color: OneDarkColors.fgDim),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: OneDarkColors.fgDim)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete', style: TextStyle(color: OneDarkColors.red)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      for (final id in _selectedIds) {
        final file = _files.firstWhere((f) => f.id == id);
        if (_currentProvider == CloudProvider.googleDrive) {
          await _gDrive.delete(id);
        } else if (_currentProvider == CloudProvider.dropbox) {
          final filePath = '$_currentPath${file.name}';
          await _dropbox.delete(filePath);
        } else {
          await _openDrive.delete(id);
        }
      }
      setState(() {
        _selectMode = false;
        _selectedIds.clear();
      });
      _listFiles();
    }
  }

  Future<void> _renameFile(CloudFile file) async {
    final controller = TextEditingController(text: file.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: OneDarkColors.bgDark,
        title: Text('Rename', style: TextStyle(color: OneDarkColors.fg)),
        content: TextField(
          controller: controller,
          style: TextStyle(color: OneDarkColors.fg),
          autofocus: true,
          decoration: InputDecoration(
            filled: true,
            fillColor: OneDarkColors.bgDark,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: OneDarkColors.dim),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: OneDarkColors.fgDim)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text('Rename', style: TextStyle(color: OneDarkColors.cyan)),
          ),
        ],
      ),
    );

    if (newName != null && newName.isNotEmpty && newName != file.name) {
      if (_currentProvider == CloudProvider.googleDrive) {
        await _gDrive.rename(file.id, newName);
      } else if (_currentProvider == CloudProvider.dropbox) {
        final oldPath = '$_currentPath${file.name}';
        final newPath = '$_currentPath$newName';
        await _dropbox.rename(oldPath, newPath);
      } else {
        await _openDrive.rename(file.id, newName);
      }
      _listFiles();
    }
  }

  Future<void> _shareFile(CloudFile file) async {
    String? url;
    if (_currentProvider == CloudProvider.googleDrive) {
      url = await _gDrive.getDownloadUrl(file.id);
    } else if (_currentProvider == CloudProvider.dropbox) {
      final filePath = '$_currentPath${file.name}';
      url = await _dropbox.getTemporaryLink(filePath);
    } else {
      url = await _openDrive.getDownloadUrl(file.id);
    }

    if (url != null && mounted) {
      await Clipboard.setData(ClipboardData(text: url));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Link copied to clipboard')),
      );
    }
  }

  void _showFileDetails(CloudFile file) {
    showModalBottomSheet(
      context: context,
      backgroundColor: OneDarkColors.bgDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  file.isDirectory ? Icons.folder : Icons.insert_drive_file,
                  color: file.isDirectory ? OneDarkColors.amber : OneDarkColors.cyan,
                  size: 32,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        file.name,
                        style: TextStyle(
                          color: OneDarkColors.fg,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        file.isDirectory ? 'Folder' : _formatSize(file.size),
                        style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (file.modifiedTime != null) ...[
              const SizedBox(height: 12),
              Text(
                'Modified: ${_formatDate(file.modifiedTime!)}',
                style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _detailButton(Icons.share, 'Share', () {
                  Navigator.pop(ctx);
                  _shareFile(file);
                }),
                _detailButton(Icons.edit, 'Rename', () {
                  Navigator.pop(ctx);
                  _renameFile(file);
                }),
                _detailButton(Icons.delete, 'Delete', () async {
                  Navigator.pop(ctx);
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (ctx2) => AlertDialog(
                      backgroundColor: OneDarkColors.bgDark,
                      title: Text('Delete "${file.name}"?', style: TextStyle(color: OneDarkColors.fg)),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx2, false),
                          child: Text('Cancel', style: TextStyle(color: OneDarkColors.fgDim)),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx2, true),
                          child: Text('Delete', style: TextStyle(color: OneDarkColors.red)),
                        ),
                      ],
                    ),
                  );
                  if (confirm == true) {
                    if (_currentProvider == CloudProvider.googleDrive) {
                      await _gDrive.delete(file.id);
                    } else if (_currentProvider == CloudProvider.dropbox) {
                      await _dropbox.delete('$_currentPath${file.name}');
                    } else {
                      await _openDrive.delete(file.id);
                    }
                    _listFiles();
                  }
                }),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _detailButton(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Icon(icon, color: OneDarkColors.cyan, size: 24),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1073741824) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    return '${(bytes / 1073741824).toStringAsFixed(1)} GB';
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} '
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OneDarkColors.bg,
      appBar: AppBar(
        backgroundColor: OneDarkColors.bgDark,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: OneDarkColors.fg),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Cloud Storage',
              style: TextStyle(color: OneDarkColors.fg, fontSize: 16),
            ),
            Text(
              _currentProvider == CloudProvider.googleDrive ? 'Google Drive'
                  : _currentProvider == CloudProvider.dropbox ? 'Dropbox'
                  : 'OpenDrive',
              style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11),
            ),
          ],
        ),
        actions: [
          if (_isConnected) ...[
            if (_selectMode) ...[
              IconButton(
                icon: Icon(Icons.close, color: OneDarkColors.fgDim),
                onPressed: () => setState(() {
                  _selectMode = false;
                  _selectedIds.clear();
                }),
              ),
              if (_selectedIds.isNotEmpty)
                IconButton(
                  icon: Icon(Icons.delete, color: OneDarkColors.red),
                  onPressed: _deleteSelected,
                ),
            ] else ...[
              IconButton(
                icon: Icon(Icons.create_new_folder, color: OneDarkColors.fgDim),
                onPressed: _createFolder,
                tooltip: 'New Folder',
              ),
              IconButton(
                icon: Icon(_uploading ? Icons.hourglass_top : Icons.upload_file, color: OneDarkColors.fgDim),
                onPressed: _uploading ? null : _uploadFile,
                tooltip: 'Upload',
              ),
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert, color: OneDarkColors.fgDim),
                color: OneDarkColors.bgDark,
                onSelected: (value) {
                  switch (value) {
                    case 'refresh':
                      _listFiles();
                      break;
                    case 'upload':
                      _uploadFile();
                      break;
                    case 'select':
                      setState(() => _selectMode = true);
                      break;
                    case 'disconnect':
                      if (_currentProvider == CloudProvider.googleDrive) {
                        _gDrive.disconnect();
                      } else if (_currentProvider == CloudProvider.dropbox) {
                        _dropbox.disconnect();
                      } else {
                        _openDrive.disconnect();
                      }
                      setState(() {});
                      break;
                    case 'google_drive':
                      setState(() {
                        _currentProvider = CloudProvider.googleDrive;
                        _files = [];
                        _currentPath = '/';
                      });
                      if (_gDrive.isConnected) _listFiles();
                      break;
                    case 'dropbox':
                      setState(() {
                        _currentProvider = CloudProvider.dropbox;
                        _files = [];
                        _currentPath = '/';
                      });
                      if (_dropbox.isConnected) _listFiles();
                      break;
                    case 'open_drive':
                      setState(() {
                        _currentProvider = CloudProvider.openDrive;
                        _files = [];
                        _currentPath = '/';
                      });
                      if (_openDrive.isConnected) _listFiles();
                      break;
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(value: 'refresh', child: Text('Refresh', style: TextStyle(color: OneDarkColors.fg))),
                  PopupMenuItem(value: 'upload', child: Text('Upload File', style: TextStyle(color: OneDarkColors.fg))),
                  PopupMenuItem(value: 'select', child: Text('Select', style: TextStyle(color: OneDarkColors.fg))),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'google_drive',
                    child: Row(
                      children: [
                        Icon(Icons.cloud, size: 18, color: _currentProvider == CloudProvider.googleDrive ? OneDarkColors.cyan : OneDarkColors.fgDim),
                        const SizedBox(width: 8),
                        Text('Google Drive', style: TextStyle(color: OneDarkColors.fg)),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'dropbox',
                    child: Row(
                      children: [
                        Icon(Icons.storage, size: 18, color: _currentProvider == CloudProvider.dropbox ? OneDarkColors.cyan : OneDarkColors.fgDim),
                        const SizedBox(width: 8),
                        Text('Dropbox', style: TextStyle(color: OneDarkColors.fg)),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'open_drive',
                    child: Row(
                      children: [
                        Icon(Icons.cloud_sync, size: 18, color: _currentProvider == CloudProvider.openDrive ? OneDarkColors.cyan : OneDarkColors.fgDim),
                        const SizedBox(width: 8),
                        Text('OpenDrive', style: TextStyle(color: OneDarkColors.fg)),
                      ],
                    ),
                  ),
                  const PopupMenuDivider(),
                  PopupMenuItem(value: 'disconnect', child: Text('Disconnect', style: TextStyle(color: OneDarkColors.red))),
                ],
              ),
            ],
          ],
        ],
      ),
      body: Column(
        children: [
          // Provider selector
          Container(
            color: OneDarkColors.bgDark,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                _providerChip(CloudProvider.googleDrive, Icons.cloud, 'Google Drive'),
                const SizedBox(width: 8),
                _providerChip(CloudProvider.dropbox, Icons.storage, 'Dropbox'),
                const SizedBox(width: 8),
                _providerChip(CloudProvider.openDrive, Icons.cloud_sync, 'OpenDrive'),
                const Spacer(),
                if (_isConnected)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: OneDarkColors.green.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.circle, size: 8, color: OneDarkColors.green),
                        const SizedBox(width: 4),
                        Text('Connected', style: TextStyle(color: OneDarkColors.green, fontSize: 11)),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          // Breadcrumb
          if (_isConnected)
            Container(
              color: OneDarkColors.bgDark,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: [
                  if (_currentPath != '/')
                    IconButton(
                      icon: Icon(Icons.arrow_back, size: 18, color: OneDarkColors.cyan),
                      onPressed: _navigateUp,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                    ),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: _buildBreadcrumb(),
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // Content
          Expanded(
            child: _buildContent(),
          ),
        ],
      ),
    );
  }

  Widget _providerChip(CloudProvider provider, IconData icon, String label) {
    final isSelected = _currentProvider == provider;
    final isConnected = (provider == CloudProvider.googleDrive && _gDrive.isConnected) ||
        (provider == CloudProvider.dropbox && _dropbox.isConnected) ||
        (provider == CloudProvider.openDrive && _openDrive.isConnected);

    return GestureDetector(
      onTap: () {
        if (_currentProvider != provider) {
          setState(() {
            _currentProvider = provider;
            _files = [];
            _currentPath = '/';
          });
          if (isConnected) _listFiles();
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? OneDarkColors.cyan.withValues(alpha: 0.2) : OneDarkColors.dim,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? OneDarkColors.cyan : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: isSelected ? OneDarkColors.cyan : OneDarkColors.fgDim),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? OneDarkColors.cyan : OneDarkColors.fgDim,
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildBreadcrumb() {
    final parts = _currentPath.split('/').where((p) => p.isNotEmpty).toList();
    final widgets = <Widget>[
      GestureDetector(
        onTap: () => _navigateToPath('/'),
        child: Text('/', style: TextStyle(color: OneDarkColors.cyan, fontSize: 12)),
      ),
    ];

    String accumulated = '/';
    for (int i = 0; i < parts.length; i++) {
      accumulated += '${parts[i]}/';
      final path = accumulated;
      widgets.add(
        GestureDetector(
          onTap: () => _navigateToPath(path),
          child: Text(
            ' ${parts[i]}/',
            style: TextStyle(color: OneDarkColors.cyan, fontSize: 12),
          ),
        ),
      );
    }

    return widgets;
  }

  Widget _buildContent() {
    if (!_isConnected) {
      return _buildConnectView();
    }

    if (_loading) {
      return Center(
        child: CircularProgressIndicator(color: OneDarkColors.cyan),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: OneDarkColors.red),
            const SizedBox(height: 12),
            Text('Error: $_error', style: TextStyle(color: OneDarkColors.fgDim)),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _listFiles,
              child: Text('Retry', style: TextStyle(color: OneDarkColors.cyan)),
            ),
          ],
        ),
      );
    }

    if (_files.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_queue, size: 48, color: OneDarkColors.fgDim),
            const SizedBox(height: 12),
            Text('No files here', style: TextStyle(color: OneDarkColors.fgDim)),
            const SizedBox(height: 8),
            Text(
              'Create a folder or upload files',
              style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _listFiles,
      color: OneDarkColors.cyan,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: _files.length,
        itemBuilder: (context, index) {
          final file = _files[index];
          final isSelected = _selectedIds.contains(file.id);

          return ListTile(
            leading: _selectMode
                ? Icon(
                    isSelected ? Icons.check_circle : Icons.circle_outlined,
                    color: isSelected ? OneDarkColors.cyan : OneDarkColors.fgDim,
                  )
                : Icon(
                    file.isDirectory ? Icons.folder : Icons.insert_drive_file,
                    color: file.isDirectory ? OneDarkColors.amber : OneDarkColors.cyan,
                  ),
            title: Text(
              file.name,
              style: TextStyle(color: OneDarkColors.fg, fontSize: 14),
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: file.isDirectory
                ? null
                : Text(
                    _formatSize(file.size),
                    style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11),
                  ),
            trailing: !_selectMode
                ? IconButton(
                    icon: Icon(Icons.more_vert, size: 18, color: OneDarkColors.fgDim),
                    onPressed: () => _showFileDetails(file),
                  )
                : null,
            onTap: () {
              if (_selectMode) {
                setState(() {
                  if (isSelected) {
                    _selectedIds.remove(file.id);
                  } else {
                    _selectedIds.add(file.id);
                  }
                });
              } else if (file.isDirectory) {
                _navigateToFolder(file);
              } else {
                _showFileDetails(file);
              }
            },
            onLongPress: file.isDirectory
                ? null
                : () {
                    if (!_selectMode) {
                      setState(() {
                        _selectMode = true;
                        _selectedIds.add(file.id);
                      });
                    }
                  },
          );
        },
      ),
    );
  }

  Widget _buildConnectView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _currentProvider == CloudProvider.googleDrive ? Icons.cloud
                  : _currentProvider == CloudProvider.dropbox ? Icons.storage
                  : Icons.cloud_sync,
              size: 64,
              color: OneDarkColors.fgDim,
            ),
            const SizedBox(height: 20),
            Text(
              _currentProvider == CloudProvider.googleDrive
                  ? 'Google Drive'
                  : _currentProvider == CloudProvider.dropbox
                  ? 'Dropbox'
                  : 'OpenDrive',
              style: TextStyle(
                color: OneDarkColors.fg,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Connect to browse your cloud files',
              style: TextStyle(color: OneDarkColors.fgDim, fontSize: 13),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: 200,
              child: ElevatedButton.icon(
                onPressed: _currentProvider == CloudProvider.googleDrive
                    ? _connectGoogleDrive
                    : _currentProvider == CloudProvider.dropbox
                        ? _connectDropbox
                        : _connectOpenDrive,
                icon: Icon(
                  _currentProvider == CloudProvider.googleDrive
                      ? Icons.cloud
                      : _currentProvider == CloudProvider.dropbox
                          ? Icons.storage
                          : Icons.cloud_sync,
                  size: 18,
                ),
                label: Text('Connect'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: OneDarkColors.cyan,
                  foregroundColor: OneDarkColors.bg,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _currentProvider == CloudProvider.googleDrive
                  ? 'You need a Google Cloud OAuth Client ID'
                  : _currentProvider == CloudProvider.dropbox
                      ? 'You need a Dropbox App Key and Secret'
                      : 'You need an OpenDrive API Key',
              style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

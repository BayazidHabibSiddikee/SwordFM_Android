import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:open_file/open_file.dart';
import '../theme/theme.dart';
import '../utils/constants.dart' show AppPaths;

/// Document scanner — capture pages from camera or gallery, assemble into PDF.
class DocumentScannerScreen extends StatefulWidget {
  const DocumentScannerScreen({super.key});
  @override
  State<DocumentScannerScreen> createState() => _ScannerState();
}

class _ScannerState extends State<DocumentScannerScreen> {
  final List<_ScannedPage> _pages = [];
  final _picker = ImagePicker();
  bool _building = false;

  Future<void> _capturePage(ImageSource source) async {
    final xfile = await _picker.pickImage(source: source, imageQuality: 95);
    if (xfile == null) return;
    setState(() => _pages.add(_ScannedPage(path: xfile.path)));
  }

  void _removePage(int index) {
    setState(() => _pages.removeAt(index));
  }

  void _reorderPage(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex--;
      final item = _pages.removeAt(oldIndex);
      _pages.insert(newIndex, item);
    });
  }

  Future<void> _buildPdf() async {
    if (_pages.isEmpty) return;
    setState(() => _building = true);
    try {
      final doc = pw.Document();
      for (final page in _pages) {
        final imageBytes = await File(page.path).readAsBytes();
        final image = pw.MemoryImage(imageBytes);
        // Fit image to A4
        final aspectRatio = image.width! / image.height!;
        final pageWidth = PdfPageFormat.a4.width;
        final pageHeight = pageWidth / aspectRatio;
        doc.addPage(
          pw.Page(
            pageFormat: PdfPageFormat(pageWidth, pageHeight, marginAll: 0),
            build: (_) => pw.Center(child: pw.Image(image, fit: pw.BoxFit.contain)),
          ),
        );
      }
      // Remember last save directory
      final prefs = await SharedPreferences.getInstance();
      final lastDir = prefs.getString('scanner_last_dir') ?? AppPaths.downloads;

      // Ask user for filename before saving
      final nameController = TextEditingController(
        text: 'scan_${DateTime.now().millisecondsSinceEpoch}.pdf',
      );
      final result = await showDialog<Map<String, String>>(
        context: context,
        builder: (ctx) => _SaveDialog(
          nameController: nameController,
          initialDir: lastDir,
        ),
      );
      if (result == null) {
        setState(() => _building = false);
        return;
      }
      final fileName = result['name']!;
      final saveDir = result['dir']!;
      // Remember this directory for next time
      await prefs.setString('scanner_last_dir', saveDir);
      final outPath = p.join(saveDir, fileName);
      final file = File(outPath);
      await file.writeAsBytes(await doc.save());
      if (mounted) {
        setState(() => _building = false);
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: OneDarkColors.bgDark,
            title: Text('PDF Created', style: TextStyle(color: OneDarkColors.fg)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_pages.length} page${_pages.length != 1 ? 's' : ''}',
                  style: TextStyle(color: OneDarkColors.fg, fontSize: 14),
                ),
                const SizedBox(height: 8),
                Text(
                  'Saved to:',
                  style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  outPath,
                  style: TextStyle(color: OneDarkColors.cyan, fontSize: 11),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.pop(context);
                  OpenFile.open(outPath);
                },
                child: const Text('Open'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _building = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: OneDarkColors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OneDarkColors.bg,
      appBar: AppBar(
        title: Text(
          'Scanner (${_pages.length} page${_pages.length != 1 ? 's' : ''})',
          style: const TextStyle(fontSize: 16),
        ),
        backgroundColor: OneDarkColors.bgDark,
        foregroundColor: OneDarkColors.fg,
        iconTheme: IconThemeData(color: OneDarkColors.fg),
        actions: [
          if (_pages.isNotEmpty)
            IconButton(
              icon: Icon(Icons.picture_as_pdf, color: OneDarkColors.red),
              tooltip: 'Build PDF',
              onPressed: _building ? null : _buildPdf,
            ),
        ],
      ),
      body: _building
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: OneDarkColors.cyan),
                  SizedBox(height: 16),
                  Text('Building PDF…', style: TextStyle(color: OneDarkColors.fgDim)),
                ],
              ),
            )
          : _pages.isEmpty
              ? _buildEmptyState()
              : _buildPageGrid(),
      bottomNavigationBar: _pages.isNotEmpty
          ? Container(
              padding: const EdgeInsets.all(12),
              color: OneDarkColors.bgDark,
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _capturePage(ImageSource.camera),
                      icon: const Icon(Icons.camera_alt, size: 18),
                      label: const Text('Camera'),
                      style: OutlinedButton.styleFrom(foregroundColor: OneDarkColors.cyan),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _capturePage(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library, size: 18),
                      label: const Text('Gallery'),
                      style: OutlinedButton.styleFrom(foregroundColor: OneDarkColors.green),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _buildPdf,
                      icon: const Icon(Icons.picture_as_pdf, size: 18),
                      label: const Text('Save PDF'),
                    ),
                  ),
                ],
              ),
            )
          : null,
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.document_scanner, size: 64, color: OneDarkColors.fgDim),
          const SizedBox(height: 16),
          Text('Scan documents', style: TextStyle(color: OneDarkColors.fg, fontSize: 18)),
          const SizedBox(height: 8),
          Text(
            'Capture pages from camera or import from gallery,\nthen save as a single PDF.',
            style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: () => _capturePage(ImageSource.camera),
                icon: const Icon(Icons.camera_alt, size: 18),
                label: const Text('Camera'),
              ),
              const SizedBox(width: 16),
              OutlinedButton.icon(
                onPressed: () => _capturePage(ImageSource.gallery),
                icon: const Icon(Icons.photo_library, size: 18),
                label: const Text('Gallery'),
                style: OutlinedButton.styleFrom(foregroundColor: OneDarkColors.cyan),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPageGrid() {
    return ReorderableListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _pages.length,
      onReorder: _reorderPage,
      itemBuilder: (_, i) {
        return Card(
          key: ValueKey(_pages[i].path),
          color: OneDarkColors.bgDark,
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.file(
                File(_pages[i].path),
                width: 48,
                height: 48,
                fit: BoxFit.cover,
              ),
            ),
            title: Text(
              'Page ${i + 1}',
              style: TextStyle(color: OneDarkColors.fg, fontSize: 13),
            ),
            subtitle: Text(
              _pages[i].path.split('/').last,
              style: TextStyle(color: OneDarkColors.fgDim, fontSize: 10),
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(Icons.delete, size: 18, color: OneDarkColors.red),
                  onPressed: () => _removePage(i),
                ),
                Icon(Icons.drag_handle, color: OneDarkColors.fgDim),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ScannedPage {
  final String path;
  const _ScannedPage({required this.path});
}

/// Save dialog that remembers the last used directory.
class _SaveDialog extends StatefulWidget {
  final TextEditingController nameController;
  final String initialDir;
  const _SaveDialog({required this.nameController, required this.initialDir});

  @override
  State<_SaveDialog> createState() => _SaveDialogState();
}

class _SaveDialogState extends State<_SaveDialog> {
  late String _saveDir;

  @override
  void initState() {
    super.initState();
    _saveDir = widget.initialDir;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: OneDarkColors.bgDark,
      title: Text('Save PDF', style: TextStyle(color: OneDarkColors.fg)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: widget.nameController,
            style: TextStyle(color: OneDarkColors.fg),
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Filename',
              labelStyle: TextStyle(color: OneDarkColors.fgDim),
              suffixText: '.pdf',
              filled: true,
              fillColor: OneDarkColors.bg,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: OneDarkColors.dim),
              ),
            ),
          ),
          const SizedBox(height: 12),
          InkWell(
            onTap: _pickFolder,
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: OneDarkColors.bg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: OneDarkColors.dim),
              ),
              child: Row(
                children: [
                  Icon(Icons.folder, size: 18, color: OneDarkColors.amber),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _saveDir,
                      style: TextStyle(color: OneDarkColors.fg, fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 18, color: OneDarkColors.fgDim),
                ],
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel', style: TextStyle(color: OneDarkColors.fgDim)),
        ),
        TextButton(
          onPressed: () {
            var name = widget.nameController.text.trim();
            if (!name.endsWith('.pdf')) name = '$name.pdf';
            Navigator.pop(context, {'name': name, 'dir': _saveDir});
          },
          child: Text('Save', style: TextStyle(color: OneDarkColors.cyan)),
        ),
      ],
    );
  }

  Future<void> _pickFolder() async {
    final dirs = [
      AppPaths.downloads,
      AppPaths.documents,
      AppPaths.home,
    ];
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bgDark,
        title: Text('Save to', style: TextStyle(color: OneDarkColors.fg)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: dirs.map((d) => ListTile(
            dense: true,
            leading: Icon(Icons.folder, size: 18, color: OneDarkColors.amber),
            title: Text(d.split('/').last, style: TextStyle(color: OneDarkColors.fg, fontSize: 13)),
            subtitle: Text(d, style: TextStyle(color: OneDarkColors.fgDim, fontSize: 10)),
            onTap: () => Navigator.pop(context, d),
          )).toList(),
        ),
      ),
    );
    if (picked != null) setState(() => _saveDir = picked);
  }
}

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:open_file/open_file.dart';
import '../theme/theme.dart';

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
      // Save to Documents
      final dir = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final outPath = p.join(dir.path, 'scan_$timestamp.pdf');
      final file = File(outPath);
      await file.writeAsBytes(await doc.save());
      if (mounted) {
        setState(() => _building = false);
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: OneDarkColors.bg,
            title: Text('PDF Created', style: TextStyle(color: OneDarkColors.fg)),
            content: Text(
              '${_pages.length} pages saved as ${p.basename(outPath)}',
              style: TextStyle(color: OneDarkColors.fgDim),
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

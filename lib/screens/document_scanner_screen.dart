import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:open_file/open_file.dart';
import '../services/ocr_service.dart';
import '../theme/theme.dart';
import '../utils/constants.dart' show AppPaths;
import '../utils/safe_file_writer.dart';

/// Document scanner — capture pages from camera or gallery, assemble into PDF.
/// Includes offline OCR (Tesseract) to pull text out of scanned pages,
/// imported images, or any PDF on the device.
class DocumentScannerScreen extends StatefulWidget {
  const DocumentScannerScreen({super.key});
  @override
  State<DocumentScannerScreen> createState() => _ScannerState();
}

class _ScannerState extends State<DocumentScannerScreen> {
  final List<_ScannedPage> _pages = [];
  final _picker = ImagePicker();
  bool _building = false;
  bool _ocrRunning = false;

  @override
  void initState() {
    super.initState();
    // Warm up OCR in the background (copies the bundled English trained data
    // out of assets on first run) so the first recognition is snappier.
    unawaited(OcrService.ensureReady().catchError((_) {}));
  }

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
      final actualPath = await writeBytesResilient(outPath, await doc.save());
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
                  actualPath,
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
                  OpenFile.open(actualPath);
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

  // ---------------------------------------------------------------------
  // OCR (offline Tesseract)
  // ---------------------------------------------------------------------

  /// Recognises text on every scanned page and shows the combined result.
  Future<void> _ocrAllPages() async {
    if (_pages.isEmpty || _ocrRunning) return;
    await _runOcr(
      () async {
        final buffer = StringBuffer();
        for (var i = 0; i < _pages.length; i++) {
          final text = await OcrService.extractText(_pages[i].path);
          if (buffer.isNotEmpty) buffer.write('\n\n');
          buffer.write('--- Page ${i + 1} ---\n$text');
        }
        return buffer.toString();
      },
    );
  }

  /// Opens a picker for any image/PDF on the device and recognises its text.
  Future<void> _ocrPickFile() async {
    if (_ocrRunning) return;
    // file_picker 12.x returns the file list directly (no result wrapper).
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'pdf'],
    );
    final path = files.isEmpty ? null : files.first.path;
    if (path == null) return;
    await _runOcr(
      () => OcrService.extractFromDocument(
        path,
        onProgress: (page, total) {
          _ocrStatus.value = 'Page $page of $total…';
        },
      ),
    );
  }

  final ValueNotifier<String> _ocrStatus =
      ValueNotifier<String>('Recognising text…');

  /// Shared runner: progress dialog → OCR → result dialog with copy/save.
  Future<void> _runOcr(Future<String> Function() job) async {
    setState(() => _ocrRunning = true);
    _ocrStatus.value = 'Recognising text…';
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          backgroundColor: OneDarkColors.bgDark,
          content: ValueListenableBuilder<String>(
            valueListenable: _ocrStatus,
            builder: (_, status, _) => Row(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(width: 20),
                Expanded(
                  child: Text(
                    status,
                    style: TextStyle(color: OneDarkColors.fg, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    try {
      final text = await job();
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // progress dialog
      _showOcrResult(text);
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('OCR failed: $e'),
          backgroundColor: OneDarkColors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _ocrRunning = false);
    }
  }

  void _showOcrResult(String text) {
    showDialog<void>(
      context: context,
      builder: (resultContext) => AlertDialog(
        backgroundColor: OneDarkColors.bgDark,
        title: Text('Recognised text',
            style: TextStyle(color: OneDarkColors.fg)),
        content: SizedBox(
          width: double.maxFinite,
          height: 320,
          child: text.trim().isEmpty
              ? Text(
                  'No text found in the image.\n\nTry a sharper photo, better '
                  'lighting, or a different page-segmentation mode.',
                  style: TextStyle(color: OneDarkColors.fgDim, fontSize: 13),
                )
              : SingleChildScrollView(
                  child: SelectableText(
                    text,
                    style: TextStyle(
                      color: OneDarkColors.fg,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(resultContext).showSnackBar(
                const SnackBar(content: Text('Copied to clipboard')),
              );
            },
            child: const Text('Copy'),
          ),
          TextButton(
            onPressed: () async {
              final name = 'ocr_${DateTime.now().millisecondsSinceEpoch}.txt';
              final dir = AppPaths.documents;
              try {
                await Directory(dir).create(recursive: true);
                await File(p.join(dir, name)).writeAsString(text);
                if (resultContext.mounted) {
                  ScaffoldMessenger.of(resultContext).showSnackBar(
                    SnackBar(
                      content: Text('Saved to $dir/$name'),
                      backgroundColor: OneDarkColors.green,
                    ),
                  );
                }
              } catch (e) {
                if (resultContext.mounted) {
                  ScaffoldMessenger.of(resultContext).showSnackBar(
                    SnackBar(
                      content: Text('Save failed: $e'),
                      backgroundColor: OneDarkColors.red,
                    ),
                  );
                }
              }
            },
            child: const Text('Save .txt'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(resultContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// Shows OCR options: recognition language (bundled English plus any extra
  /// .traineddata files copied into the tessdata folder) and the page
  /// segmentation mode Tesseract should use. Both persist across sessions.
  Future<void> _showOcrSettings() async {
    await OcrService.ensureReady();
    if (!mounted) return;
    final savedPrefs = await OcrService.loadPrefs();
    String language = savedPrefs[0];
    String psm = savedPrefs[1];
    await showDialog<void>(
      context: context,
      builder: (settingsContext) => StatefulBuilder(
        builder: (settingsContext, setDialogState) => AlertDialog(
          backgroundColor: OneDarkColors.bgDark,
          title:
              Text('OCR settings', style: TextStyle(color: OneDarkColors.fg)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Language',
                  style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11)),
              const SizedBox(height: 4),
              DropdownButton<String>(
                value: OcrService.availableLanguages.contains(language)
                    ? language
                    : 'eng',
                isExpanded: true,
                dropdownColor: OneDarkColors.bg,
                items: [
                  for (final lang in OcrService.availableLanguages)
                    DropdownMenuItem(
                        value: lang, child: Text(lang, style: TextStyle(color: OneDarkColors.fg))),
                ],
                onChanged: (v) => setDialogState(() => language = v ?? 'eng'),
              ),
              const SizedBox(height: 12),
              Text('Page segmentation',
                  style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11)),
              const SizedBox(height: 4),
              DropdownButton<String>(
                value: OcrService.psmModes.containsValue(psm)
                    ? psm
                    : '3',
                isExpanded: true,
                dropdownColor: OneDarkColors.bg,
                items: [
                  for (final entry in OcrService.psmModes.entries)
                    DropdownMenuItem(
                        value: entry.value,
                        child: Text(entry.key,
                            style: TextStyle(color: OneDarkColors.fg))),
                ],
                onChanged: (v) => setDialogState(() => psm = v ?? '3'),
              ),
              const SizedBox(height: 8),
              Text(
                'Extra languages: copy a .traineddata file from the '
                'Tesseract tessdata project into ${OcrService.tessDataPath.isEmpty ? "the app tessdata folder (available after first OCR run)" : OcrService.tessDataPath}.',
                style: TextStyle(color: OneDarkColors.fgDim, fontSize: 10),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(settingsContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                OcrService.savePrefs(language: language, psm: psm);
                Navigator.pop(settingsContext);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
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
          IconButton(
            icon: Icon(Icons.tune, color: OneDarkColors.fgDim),
            tooltip: 'OCR settings (language, segmentation)',
            onPressed: _ocrRunning ? null : _showOcrSettings,
          ),
          if (_pages.isNotEmpty)
            IconButton(
              icon: Icon(Icons.document_scanner, color: OneDarkColors.cyan),
              tooltip: 'Recognize text (OCR) on all pages',
              onPressed: _building || _ocrRunning ? null : _ocrAllPages,
            ),
          IconButton(
            icon: Icon(Icons.find_in_page, color: OneDarkColors.cyan),
            tooltip: 'Recognize text (OCR) from an image or PDF…',
            onPressed: _ocrRunning ? null : _ocrPickFile,
          ),
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

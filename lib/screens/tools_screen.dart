import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../theme/theme.dart';
import 'document_scanner_screen.dart';
import 'cast_screen.dart';
import 'notepad_screen.dart';
import 'duplicates_screen.dart';
import '../widgets/batch_convert_dialog.dart';
import 'file_picker_screen.dart';
import '../services/ocr_service.dart';

import 'package:url_launcher/url_launcher.dart';

class ToolsScreen extends StatefulWidget {
  const ToolsScreen({super.key});

  @override
  State<ToolsScreen> createState() => _ToolsScreenState();
}

class _ToolsScreenState extends State<ToolsScreen> {
  String _ocrLanguage = 'eng';
  String _ocrPsm = '3';

  @override
  void initState() {
    super.initState();
    OcrService.loadPrefs().then((prefs) {
      if (mounted) {
        setState(() {
          _ocrLanguage = prefs[0];
          _ocrPsm = prefs[1];
        });
      }
    });
  }

  void _showOcrLanguagePicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: OneDarkColors.bgDark,
      builder: (ctx) {
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: OcrService.availableLanguagesWithLabels.map((lang) {
            return ListTile(
              title: Text(lang.value, style: TextStyle(color: OneDarkColors.fg)),
              trailing: _ocrLanguage == lang.key ? Icon(Icons.check, color: OneDarkColors.cyan) : null,
              onTap: () {
                OcrService.savePrefs(language: lang.key);
                setState(() => _ocrLanguage = lang.key);
                Navigator.pop(ctx);
              },
            );
          }).toList(),
        );
      },
    );
  }

  void _showOcrPsmPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: OneDarkColors.bgDark,
      builder: (ctx) {
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: OcrService.psmModes.entries.map((e) {
            return ListTile(
              title: Text(e.key, style: TextStyle(color: OneDarkColors.fg)),
              trailing: _ocrPsm == e.value ? Icon(Icons.check, color: OneDarkColors.cyan) : null,
              onTap: () {
                OcrService.savePrefs(psm: e.value);
                setState(() => _ocrPsm = e.value);
                Navigator.pop(ctx);
              },
            );
          }).toList(),
        );
      },
    );
  }

  Future<void> _openConverter() async {
    final result = await Navigator.push<List<String>>(
      context,
      MaterialPageRoute(builder: (_) => const FilePickerScreen()),
    );
    if (result == null || result.isEmpty) return;
    
    if (mounted) {
      showDialog(
        context: context,
        builder: (_) => BatchConvertDialog(filePaths: result),
      );
    }
  }

  Future<void> _openRcloneBrowser() async {
    final uri = Uri.parse('termux://com.termux.app?action=run_command&command=rclone%20browser');
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      } else {
        if (!mounted) return;
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: OneDarkColors.bg,
            title: Text('rclone Browser', style: TextStyle(color: OneDarkColors.fg)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Open Termux and run:', style: TextStyle(color: OneDarkColors.fg)),
                const SizedBox(height: 8),
                Text('rclone browser', style: TextStyle(color: OneDarkColors.cyan, fontFamily: 'monospace')),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      debugPrint('_openRcloneBrowser error: $e');
    }
  }

  Widget _toolTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon, color: OneDarkColors.cyan),
      title: Text(title, style: TextStyle(color: OneDarkColors.fg, fontWeight: FontWeight.bold)),
      subtitle: Text(subtitle, style: TextStyle(color: OneDarkColors.fgDim, fontSize: 13)),
      trailing: Icon(Icons.chevron_right, color: OneDarkColors.fgDim),
      onTap: onTap,
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          color: OneDarkColors.purple,
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tools'),
        backgroundColor: OneDarkColors.bg,
        foregroundColor: OneDarkColors.fg,
      ),
      body: ListView(
        children: [
          _sectionTitle('Productivity & Documents'),
          _toolTile(
            icon: Icons.sync,
            title: 'Document Converter',
            subtitle: 'Convert between PDF, DOCX, MD, Images, etc.',
            onTap: _openConverter,
          ),
          _toolTile(
            icon: Icons.document_scanner,
            title: 'Document Scanner',
            subtitle: 'Scan physical pages into a PDF',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DocumentScannerScreen())),
          ),
          _toolTile(
            icon: Icons.sticky_note_2,
            title: 'Notepad',
            subtitle: 'Create and edit plain text documents',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NotepadScreen())),
          ),
          
          _sectionTitle('Utilities'),
          _toolTile(
            icon: Icons.cloud,
            title: 'rclone Cloud Mounts',
            subtitle: 'Browse cloud storage via rclone (requires Termux)',
            onTap: _openRcloneBrowser,
          ),
          _toolTile(
            icon: Icons.all_inclusive,
            title: 'Find Duplicates',
            subtitle: 'Scan for duplicate files by hash',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DuplicatesScreen())),
          ),
          _toolTile(
            icon: Icons.cast,
            title: 'Cast Media',
            subtitle: 'Discover and stream to Chromecast / DLNA devices',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CastScreen())),
          ),

          _sectionTitle('OCR / Text Recognition'),
          _toolTile(
            icon: Icons.translate,
            title: 'Recognition Language',
            subtitle: 'Language used by Tesseract OCR',
            onTap: () => _showOcrLanguagePicker(context),
          ),
          _toolTile(
            icon: Icons.tune,
            title: 'Page Segmentation Mode',
            subtitle: 'How Tesseract analyses the page layout',
            onTap: () => _showOcrPsmPicker(context),
          ),
        ],
      ),
    );
  }
}

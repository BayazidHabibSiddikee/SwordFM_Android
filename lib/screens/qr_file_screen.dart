import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:path/path.dart' as p;
import '../theme/theme.dart';

/// Shows a QR code encoding the file/folder path for sharing.
class QrFileScreen extends StatelessWidget {
  final String filePath;
  final String? lanUrl; // If on LAN, encode the download URL instead
  const QrFileScreen({super.key, required this.filePath, this.lanUrl});

  @override
  Widget build(BuildContext context) {
    final name = p.basename(filePath);
    final isDir = FileSystemEntity.isDirectorySync(filePath);
    final qrData = lanUrl ?? 'swordfm://open?path=${Uri.encodeComponent(filePath)}';
    final size = isDir ? Icons.folder : _iconForExt(p.extension(filePath));

    return AlertDialog(
      backgroundColor: OneDarkColors.bg,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(size, size: 36, color: OneDarkColors.cyan),
          const SizedBox(height: 8),
          Text(
            name,
            style: TextStyle(color: OneDarkColors.fg, fontSize: 14, fontWeight: FontWeight.w600),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
          Text(
            isDir ? 'Folder' : 'File',
            style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
            ),
            child: QrImageView(
              data: qrData,
              version: QrVersions.auto,
              size: 180.0,
              gapless: false,
              eyeStyle: QrEyeStyle(color: OneDarkColors.bg),
              dataModuleStyle: QrDataModuleStyle(color: OneDarkColors.bg),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            lanUrl != null ? 'Scan to download' : 'Scan to open in SwordFM',
            style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: qrData));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Link copied to clipboard'),
                backgroundColor: OneDarkColors.green,
              ),
            );
          },
          child: Text('Copy Link', style: TextStyle(color: OneDarkColors.cyan)),
        ),
      ],
    );
  }

  IconData _iconForExt(String ext) {
    switch (ext.toLowerCase()) {
      case '.jpg' || '.jpeg' || '.png' || '.gif' || '.webp' || '.bmp':
        return Icons.image;
      case '.mp4' || '.mkv' || '.avi' || '.mov':
        return Icons.video_file;
      case '.mp3' || '.wav' || '.flac' || '.aac' || '.ogg':
        return Icons.audio_file;
      case '.pdf':
        return Icons.picture_as_pdf;
      case '.zip' || '.tar' || '.gz' || '.rar' || '.7z':
        return Icons.archive;
      case '.txt' || '.md' || '.log':
        return Icons.description;
      case '.dart' || '.py' || '.js' || '.ts' || '.java' || '.kt' || '.c' || '.cpp' || '.go' || '.rs':
        return Icons.code;
      case '.doc' || '.docx':
        return Icons.article;
      case '.xls' || '.xlsx' || '.csv':
        return Icons.table_chart;
      case '.ppt' || '.pptx':
        return Icons.slideshow;
      case '.apk':
        return Icons.android;
      default:
        return Icons.insert_drive_file;
    }
  }
}

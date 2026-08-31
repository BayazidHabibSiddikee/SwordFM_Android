import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../services/open_with_service.dart';
import '../theme/theme.dart';
import '../utils/file_utils.dart';

/// A collapsible panel that previews the selected file.
class PreviewPanel extends StatefulWidget {
  final FileItem? item;
  final double width;
  final double? height;

  /// Called when the header close button is tapped (dismisses the hosting
  /// bottom sheet, or collapses the side panel).
  final VoidCallback? onClose;

  /// Called when the user swipes horizontally on the panel to open full screen.
  final VoidCallback? onSwipe;

  const PreviewPanel({
    super.key,
    required this.item,
    required this.width,
    this.height,
    this.onClose,
    this.onSwipe,
  });

  @override
  State<PreviewPanel> createState() => _PreviewPanelState();
}

class _PreviewPanelState extends State<PreviewPanel> {
  String _content = '';
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadContent();
  }

  @override
  void didUpdateWidget(covariant PreviewPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item?.path != widget.item?.path) {
      _loadContent();
    }
  }

  void _openFullScreen(FileItem item) {
    OpenWithService.openDefault(item.path);
  }

  Future<void> _loadContent() async {
    if (widget.item == null) {
      setState(() {
        _content = '';
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _content = '';
      _error = null;
    });

    try {
      final path = widget.item!.path;
      if (widget.item!.isVideo) {
        // Videos are opened via external player — nothing to load for preview
      } else if (widget.item!.isPdf) {
        // PDFs are opened via external app — nothing to load for preview
      } else if (widget.item!.isMarkdown) {
        _content = await _readTextInIsolate(path);
      } else if (widget.item!.extension.toLowerCase() == '.docx') {
        // DOCX is a ZIP binary — pull the text out in a background isolate so
        // the (potentially large) ZIP decode + XML regex never blocks the UI.
        _content = await Isolate.run(() => _extractDocxTextSync(path));
      } else if (widget.item!.isText || widget.item!.isCode) {
        _content = await _readTextInIsolate(path);
      }
    } catch (e) {
      setState(() {
        _error = 'Failed to load preview: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  /// Reads a text/code/markdown file off the UI isolate. Passes only the path
  /// (isolates cannot receive a [File] object) and caps reads at 512 KB so a
  /// huge file never stalls either thread. Returns a trimmed marker when the
  /// file is bigger than the cap.
  static Future<String> _readTextInIsolate(String path) {
    return Isolate.run(() {
      final file = File(path);
      if (!file.existsSync()) return '[File not found]';
      final length = file.lengthSync();
      if (length > 512 * 1024) {
        final raf = file.openSync();
        try {
          final data = raf.readSync(512 * 1024);
          return '${utf8.decode(data, allowMalformed: true)}\n… (truncated)';
        } finally {
          raf.closeSync();
        }
      }
      return file.readAsStringSync();
    });
  }

  /// Top-level (isolate-safe) DOCX text extraction. Reads the file itself from
  /// [sourcePath] — no [File] objects cross the isolate boundary.
  /// Returns `[File not found]` / `[File too large to preview]` /
  /// `[No text content found]` placeholders instead of throwing.
  static String _extractDocxTextSync(String sourcePath) {
    try {
      final file = File(sourcePath);
      if (!file.existsSync()) return '[File not found]';
      if (file.lengthSync() > 8 * 1024 * 1024) {
        return '[File too large to preview]';
      }
      final bytes = file.readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(bytes);
      final docXml = archive.findFile('word/document.xml');
      if (docXml == null) return '[No text content found]';
      var xml = utf8.decode(docXml.content as List<int>);
      // Paragraph and row endings → newlines, then strip all remaining tags.
      xml = xml
          .replaceAll('</w:p>', '\n')
          .replaceAll('</w:tr>', '\n')
          .replaceAll('<w:tab/>', '\t')
          .replaceAll(RegExp(r'<[^>]+>'), '');
      return xml
          .replaceAll('&amp;', '&')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&quot;', '"')
          .replaceAll('&apos;', "'")
          .trim();
    } catch (e) {
      return '[Could not read document: $e]';
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    if (item == null) {
      return const SizedBox.shrink();
    }

    final cs = Theme.of(context).colorScheme;

    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: GestureDetector(
        // Tapping anywhere on the panel closes it (the close button and inner
        // controls still win the gesture arena for their own taps).
        onTap: widget.onClose,
        onPanUpdate: (details) {
          // Swipe horizontally to open full screen
          if (details.delta.dx.abs() > 50) {
            widget.onSwipe?.call();
          }
        },
        child: Card(
          margin: const EdgeInsets.all(8),
          color: cs.surfaceContainerHighest,
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(item.icon, color: item.iconColor, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      item.name,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // Expand button — opens in full-screen reader/player
                  IconButton(
                    icon: const Icon(Icons.fullscreen, size: 18),
                    onPressed: () => _openFullScreen(item),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    tooltip: 'Open full screen',
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: widget.onClose ?? () {},
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Content
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(
                      child: Text(
                        _error!,
                        style: TextStyle(color: cs.error),
                      ),
                    )
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: _buildPreview(),
                    ),
            ),
          ],
        ),
        ),
      ),
    );
  }

  Widget _buildPreview() {
    final item = widget.item!;
    final cs = Theme.of(context).colorScheme;
    if (item.isPdf) {
      return _buildMetadataCard();
    }
    if (item.isVideo) {
      return GestureDetector(
        onTap: () => _openFullScreen(item),
        child: Column(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: Container(
                  width: double.infinity,
                  color: OneDarkColors.bgDark,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.movie, size: 64, color: OneDarkColors.cyan),
                      const SizedBox(height: 8),
                      Text(
                        item.name,
                        style: TextStyle(color: OneDarkColors.fg, fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          shape: BoxShape.circle,
                        ),
                        padding: const EdgeInsets.all(12),
                        child: const Icon(
                          Icons.play_arrow,
                          color: Colors.white,
                          size: 40,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Tap to play video',
              style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11),
            ),
          ],
        ),
      );
    }
    if (item.isImage) {
      return GestureDetector(
        onTap: () => _openFullScreen(item),
        child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: Image.file(
                File(item.path),
                fit: BoxFit.contain,
                // Decode at most 1000px wide — full-res photos (10MB+) are
                // slow to decode on mobile and would stall the preview.
                cacheWidth: 1000,
                errorBuilder: (_, _, _) => Icon(
                  Icons.broken_image,
                  size: 48,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: () async {
              try {
                await OpenWithService.openDefault(item.path);
              } catch (_) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text('No app can open this file'),
                      backgroundColor: OneDarkColors.red,
                    ),
                  );
                }
              }
            },
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('Open with…'),
          ),
        ],
      ),
      );
    }
    if (item.isMarkdown) {
      return MarkdownBody(
        data: _content,
        styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
          p: TextStyle(color: cs.onSurface, fontSize: 13),
          code: TextStyle(
            color: cs.primary,
            fontFamily: 'monospace',
            fontSize: 12,
          ),
          codeblockDecoration: BoxDecoration(color: cs.surfaceContainerHighest),
        ),
      );
    }
    if (item.isText || item.extension.toLowerCase() == '.docx') {
      return SelectableText(
        _content,
        style: TextStyle(
          color: cs.onSurface,
          fontSize: 12,
          fontFamily: 'monospace',
        ),
      );
    }
    if (item.isDirectory) {
      return _buildMetadataCard();
    }
    // Unsupported types: metadata + open button
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildMetadataCard(),
        const SizedBox(height: 12),
        Center(
          child: FilledButton.icon(
            onPressed: () async {
              try {
                await OpenWithService.openDefault(item.path);
              } catch (_) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text('No app can open this file'),
                      backgroundColor: cs.error,
                    ),
                  );
                }
              }
            },
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('Open with…'),
          ),
        ),
      ],
    );
  }

  Widget _buildMetadataCard() {
    final item = widget.item!;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(item.icon, size: 40, color: item.iconColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    item.isDirectory
                        ? 'Folder'
                        : item.mimeType == 'application/octet-stream'
                        ? item.extension.isEmpty
                              ? 'File'
                              : '${item.extension.toUpperCase().replaceAll('.', '')} file'
                        : item.mimeType,
                    style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontSize: 11,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _metaRow('Size', item.formattedSize),
        _metaRow('Modified', item.formattedDate),
        _metaRow(
          'Type',
          item.extension.isEmpty
              ? 'Folder'
              : item.extension.toUpperCase().replaceAll('.', ''),
        ),
        _metaRow('Path', item.path),
      ],
    );
  }

  Widget _metaRow(String label, String value) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Text(
              label,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(color: cs.onSurface, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

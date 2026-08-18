import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../utils/file_utils.dart';
import '../theme/theme.dart';

/// A collapsible panel that previews the selected file.
class PreviewPanel extends StatefulWidget {
  final FileItem? item;
  final double width;
  final bool isVisible;

  const PreviewPanel({
    super.key,
    required this.item,
    required this.width,
    required this.isVisible,
  });

  @override
  State<PreviewPanel> createState() => _PreviewPanelState();
}

class _PreviewPanelState extends State<PreviewPanel> {
  String _content = '';
  bool _loading = false;
  String? _error;

  @override
  void didUpdateWidget(covariant PreviewPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item?.path != widget.item?.path || !oldWidget.isVisible && widget.isVisible) {
      _loadContent();
    }
  }

  Future<void> _loadContent() async {
    if (widget.item == null) {
      setState(() { _content = ''; _error = null; });
      return;
    }
    setState(() { _loading = true; _content = ''; _error = null; });

    try {
      final path = widget.item!.path;
      if (widget.item!.isImage) {
        // Images rendered directly via Image.file in _buildPreview
      } else if (widget.item!.isMarkdown) {
        final file = File(path);
        if (await file.exists()) {
          _content = await file.readAsString();
        } else {
          _content = '[File not found]';
        }
      } else if (widget.item!.isText) {
        final file = File(path);
        if (await file.exists()) {
          _content = await file.readAsString();
        }
      }
    } catch (e) {
      setState(() { _error = 'Failed to load preview: $e'; });
    } finally {
      if (mounted) setState(() { _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    if (!widget.isVisible || item == null) {
      return const SizedBox.shrink();
    }

    return SizedBox(
      width: widget.width,
      child: Card(
        margin: const EdgeInsets.all(8),
        color: OneDarkColors.bgDark,
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
                      style: const TextStyle(color: OneDarkColors.fg, fontSize: 13, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () {},
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
                      ? Center(child: Text(_error!, style: const TextStyle(color: OneDarkColors.red)))
                      : SingleChildScrollView(
                          padding: const EdgeInsets.all(12),
                          child: _buildPreview(),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview() {
    final item = widget.item!;
    if (item.isImage) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.file(
          File(item.path),
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => const Icon(Icons.broken_image, size: 48, color: OneDarkColors.fgDim),
        ),
      );
    }
    if (item.isMarkdown) {
      return MarkdownBody(
        data: _content,
        styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
          p: const TextStyle(color: OneDarkColors.fg, fontSize: 13),
          code: const TextStyle(color: OneDarkColors.amber, fontFamily: 'monospace', fontSize: 12),
          codeblockDecoration: const BoxDecoration(color: OneDarkColors.dim),
        ),
      );
    }
    if (item.isText) {
      return SelectableText(
        _content,
        style: const TextStyle(color: OneDarkColors.fg, fontSize: 12, fontFamily: 'monospace'),
      );
    }
    if (item.isDirectory) {
      return _buildMetadataCard();
    }
    // Fallback for unsupported types
    return _buildMetadataCard();
  }

  Widget _buildMetadataCard() {
    final item = widget.item!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _metaRow('Size', item.formattedSize),
        _metaRow('Modified', item.formattedDate),
        _metaRow('Type', item.extension.isEmpty ? 'Folder' : item.extension.toUpperCase().replaceAll('.', '')),
        _metaRow('Path', item.path),
      ],
    );
  }

  Widget _metaRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Text(label, style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 12)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(color: OneDarkColors.fg, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:xml/xml.dart';
import '../theme/theme.dart';

/// In-app EPUB reader.
///
/// Parses the EPUB ZIP structure:
///   META-INF/container.xml → OPF path → spine item order
/// Each spine item (XHTML) is rendered as stripped text with font-size control.
class EpubReaderScreen extends StatefulWidget {
  final String filePath;
  const EpubReaderScreen({super.key, required this.filePath});

  @override
  State<EpubReaderScreen> createState() => _EpubReaderState();
}

class _EpubReaderState extends State<EpubReaderScreen> {
  bool _loading = true;
  String? _error;

  final List<_EpubChapter> _chapters = [];
  int _chapterIndex = 0;
  double _fontSize = 15.0;
  final PageController _pageController = PageController();

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _parse() async {
    try {
      final bytes = await File(widget.filePath).readAsBytes();
      final zip = ZipDecoder().decodeBytes(bytes);

      // 1. Find OPF path from META-INF/container.xml
      final containerFile = zip.findFile('META-INF/container.xml');
      if (containerFile == null) throw Exception('Not a valid EPUB: missing META-INF/container.xml');
      final containerXml = utf8.decode(containerFile.readBytes()!, allowMalformed: true);
      final container = XmlDocument.parse(containerXml);
      final opfPath = container
          .findAllElements('rootfile')
          .firstOrNull
          ?.getAttribute('full-path');
      if (opfPath == null) throw Exception('Cannot find OPF path');

      // 2. Parse OPF to get spine + manifest
      final opfFile = zip.findFile(opfPath);
      if (opfFile == null) throw Exception('Cannot find OPF file: $opfPath');
      final opfXml = utf8.decode(opfFile.readBytes()!, allowMalformed: true);
      final opf = XmlDocument.parse(opfXml);

      // Build manifest: id → href map
      final opfDir = opfPath.contains('/')
          ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1)
          : '';
      final manifest = <String, String>{};
      final manifestTitles = <String, String>{};
      for (final item in opf.findAllElements('item')) {
        final id = item.getAttribute('id') ?? '';
        final href = item.getAttribute('href') ?? '';
        manifest[id] = href;
      }

      // Build title map from toc.ncx or nav.xhtml if available
      final tocId = opf
          .findAllElements('spine')
          .firstOrNull
          ?.getAttribute('toc');
      if (tocId != null && manifest.containsKey(tocId)) {
        final tocPath = opfDir + manifest[tocId]!;
        final tocFile = zip.findFile(tocPath);
        if (tocFile != null) {
          try {
            final tocXml = utf8.decode(tocFile.readBytes()!, allowMalformed: true);
            final tocDoc = XmlDocument.parse(tocXml);
            for (final np in tocDoc.findAllElements('navPoint')) {
              final src = np
                  .findAllElements('content')
                  .firstOrNull
                  ?.getAttribute('src')
                  ?.split('#')
                  .first ?? '';
              final label = np
                  .findAllElements('text')
                  .firstOrNull
                  ?.innerText
                  .trim() ?? '';
              if (src.isNotEmpty && label.isNotEmpty) {
                manifestTitles[src] = label;
              }
            }
          } catch (_) {}
        }
      }

      // 3. Walk spine items in order
      final spineItems = opf.findAllElements('itemref').toList();
      for (final ref in spineItems) {
        final idref = ref.getAttribute('idref') ?? '';
        final href = manifest[idref];
        if (href == null) continue;
        final fullPath = opfDir + href;
        final f = zip.findFile(fullPath);
        if (f == null) continue;
        final raw = utf8.decode(f.readBytes()!, allowMalformed: true);
        final text = _xhtmlToText(raw);
        if (text.trim().isEmpty) continue;
        final hrefBasename = href.split('/').last;
        final title = manifestTitles[hrefBasename] ??
            manifestTitles[href] ??
            'Chapter ${_chapters.length + 1}';
        _chapters.add(_EpubChapter(title: title, text: text));
      }

      if (_chapters.isEmpty) throw Exception('No readable content found in EPUB');
      setState(() => _loading = false);
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// Strip HTML/XHTML tags and decode entities to plain text.
  String _xhtmlToText(String html) {
    var text = html
        .replaceAll(RegExp(r'<style[^>]*>[\s\S]*?</style>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<script[^>]*>[\s\S]*?</script>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<br\s*/?>'), '\n')
        .replaceAll(RegExp(r'<p[^>]*>'), '\n')
        .replaceAll(RegExp(r'</p>'), '\n')
        .replaceAll(RegExp(r'<h[1-6][^>]*>'), '\n\n')
        .replaceAll(RegExp(r'</h[1-6]>'), '\n\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    return text;
  }

  void _goToChapter(int index) {
    setState(() => _chapterIndex = index);
    _pageController.jumpToPage(index);
  }

  @override
  Widget build(BuildContext context) {
    final bookName = widget.filePath.split('/').last;

    if (_loading) {
      return Scaffold(
        backgroundColor: OneDarkColors.bg,
        body: Center(child: CircularProgressIndicator(color: OneDarkColors.cyan)),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: OneDarkColors.bg,
        appBar: AppBar(
          backgroundColor: OneDarkColors.bgDark,
          title: Text(bookName,
              style: TextStyle(color: OneDarkColors.fg, fontSize: 14)),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Could not open EPUB:\n$_error',
                style: TextStyle(color: OneDarkColors.red, fontSize: 13),
                textAlign: TextAlign.center),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: OneDarkColors.bg,
      appBar: AppBar(
        backgroundColor: OneDarkColors.bgDark,
        title: Text(
          _chapters[_chapterIndex].title,
          style: TextStyle(color: OneDarkColors.fg, fontSize: 14),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          // Font size decrease
          IconButton(
            icon: Icon(Icons.text_decrease, color: OneDarkColors.fg),
            onPressed: () =>
                setState(() => _fontSize = (_fontSize - 1).clamp(10, 30)),
            tooltip: 'Smaller text',
          ),
          // Font size increase
          IconButton(
            icon: Icon(Icons.text_increase, color: OneDarkColors.fg),
            onPressed: () =>
                setState(() => _fontSize = (_fontSize + 1).clamp(10, 30)),
            tooltip: 'Larger text',
          ),
          // Chapter list
          IconButton(
            icon: Icon(Icons.list, color: OneDarkColors.fg),
            onPressed: () => _showChapterList(context),
            tooltip: 'Chapters',
          ),
        ],
      ),
      body: Column(
        children: [
          // Page indicator
          Container(
            color: OneDarkColors.bgDark,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Chapter ${_chapterIndex + 1} of ${_chapters.length}',
                  style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11),
                ),
                Text(
                  '${(_fontSize).round()}pt',
                  style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11),
                ),
              ],
            ),
          ),
          Expanded(
            child: PageView.builder(
              controller: _pageController,
              itemCount: _chapters.length,
              onPageChanged: (i) => setState(() => _chapterIndex = i),
              itemBuilder: (_, i) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: SelectableText(
                    _chapters[i].text,
                    style: TextStyle(
                      color: OneDarkColors.fg,
                      fontSize: _fontSize,
                      height: 1.6,
                    ),
                  ),
                );
              },
            ),
          ),
          // Prev / Next navigation
          Container(
            color: OneDarkColors.bgDark,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton.icon(
                  onPressed: _chapterIndex > 0
                      ? () => _goToChapter(_chapterIndex - 1)
                      : null,
                  icon: Icon(Icons.chevron_left, color: OneDarkColors.cyan),
                  label: Text('Previous',
                      style: TextStyle(color: OneDarkColors.cyan)),
                ),
                TextButton.icon(
                  onPressed: _chapterIndex < _chapters.length - 1
                      ? () => _goToChapter(_chapterIndex + 1)
                      : null,
                  icon: Icon(Icons.chevron_right, color: OneDarkColors.cyan),
                  label: Text('Next',
                      style: TextStyle(color: OneDarkColors.cyan)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showChapterList(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: OneDarkColors.bg,
      builder: (_) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text('Chapters',
                style: TextStyle(
                    color: OneDarkColors.fg, fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _chapters.length,
              itemBuilder: (_, i) {
                final isCurrent = i == _chapterIndex;
                return ListTile(
                  dense: true,
                  title: Text(
                    _chapters[i].title,
                    style: TextStyle(
                      color: isCurrent ? OneDarkColors.cyan : OneDarkColors.fg,
                      fontWeight:
                          isCurrent ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  trailing: isCurrent
                      ? Icon(Icons.bookmark, color: OneDarkColors.cyan, size: 16)
                      : null,
                  onTap: () {
                    Navigator.pop(context);
                    _goToChapter(i);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _EpubChapter {
  final String title;
  final String text;
  const _EpubChapter({required this.title, required this.text});
}

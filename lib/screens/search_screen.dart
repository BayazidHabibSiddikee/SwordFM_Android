import 'dart:async';
import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';
import 'package:path/path.dart' as p;
import '../services/search_service.dart';
import '../theme/theme.dart';
import '../utils/file_utils.dart';

/// Search screen — recursive filename search with result list.
class SearchScreen extends StatefulWidget {
  final String startPath;

  const SearchScreen({super.key, required this.startPath});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  List<FileItem> _results = [];
  bool _loading = false;
  String? _error;
  int _resultCount = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onSearchChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Timer? _debounce;
  void _onSearchChanged() {
    _debounce?.cancel();
    final query = _controller.text.trim();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (query.isEmpty) {
        setState(() { _results = []; _resultCount = 0; _error = null; });
        return;
      }
      _runSearch(query);
    });
  }

  Future<void> _runSearch(String query) async {
    setState(() { _loading = true; _error = null; });
    try {
      final results = await SearchService.searchDirectory(
        widget.startPath, query, includeHidden: false, limit: 300,
      );
      if (mounted) {
        setState(() {
          _results = results;
          _resultCount = results.length;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _error = 'Search failed: $e'; _loading = false; });
    }
  }

  Future<void> _openItem(FileItem item) async {
    if (item.isDirectory) {
      // Navigate into directory via file browser
      Navigator.pop(context, item.path);
    } else {
      final result = await OpenFile.open(item.path);
      if (!mounted) return;
      if (result.type != ResultType.done) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cannot open: ${result.message}'), backgroundColor: OneDarkColors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OneDarkColors.bg,
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          focusNode: _focusNode,
          style: const TextStyle(color: OneDarkColors.fg),
          decoration: const InputDecoration(
            hintText: 'Search files…',
            hintStyle: TextStyle(color: OneDarkColors.fgDim),
            border: InputBorder.none,
          ),
          autofocus: true,
          onChanged: (_) {}, // handled by listener
        ),
        backgroundColor: OneDarkColors.bgDark,
        foregroundColor: OneDarkColors.fg,
        iconTheme: const IconThemeData(color: OneDarkColors.fg),
      ),
      body: Column(
        children: [
          // Results summary
          if (_resultCount > 0 || _loading)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: OneDarkColors.bgDark,
              child: Row(
                children: [
                  Icon(Icons.search, size: 16, color: OneDarkColors.cyan),
                  const SizedBox(width: 8),
                  Text(
                    _loading ? 'Searching…' : '$_resultCount result${_resultCount != 1 ? 's' : ''}',
                    style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
                  ),
                ],
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!, style: const TextStyle(color: OneDarkColors.red)),
            ),
          Expanded(
            child: _loading && _results.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _results.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.search_off, size: 48, color: OneDarkColors.fgDim),
                            const SizedBox(height: 12),
                            Text(
                              _controller.text.trim().isEmpty ? 'Type to search' : 'No results found',
                              style: TextStyle(color: OneDarkColors.fgDim),
                            ),
                          ],
                        ),
                      )
                    : ListView.separated(
                        itemCount: _results.length,
                        separatorBuilder: (_, index) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final item = _results[index];
                          return ListTile(
                            leading: Icon(item.icon, size: 24, color: item.iconColor),
                            title: Text(item.name, style: const TextStyle(color: OneDarkColors.fg)),
                            subtitle: Text(
                              '${item.formattedSize} · ${p.dirname(item.path)}',
                              style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 11),
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => _openItem(item),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

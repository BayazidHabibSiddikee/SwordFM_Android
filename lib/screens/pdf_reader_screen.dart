import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfx/pdfx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/doc_converter.dart';
import '../services/share_service.dart';

// ─── Mark model ───────────────────────────────────────────────────────────────

enum MarkTool { none, highlight, underline, eraser }

class PdfMark {
  final int page;
  final Offset start; // fractional (0–1) coords within the page rect
  final Offset end;
  final MarkTool tool;
  const PdfMark({
    required this.page,
    required this.start,
    required this.end,
    required this.tool,
  });

  Map<String, dynamic> toJson() => {
        'page': page,
        'sx': start.dx, 'sy': start.dy,
        'ex': end.dx, 'ey': end.dy,
        'tool': tool.index,
      };

  factory PdfMark.fromJson(Map<String, dynamic> j) => PdfMark(
        page: j['page'] as int,
        start: Offset((j['sx'] as num).toDouble(), (j['sy'] as num).toDouble()),
        end: Offset((j['ex'] as num).toDouble(), (j['ey'] as num).toDouble()),
        tool: MarkTool.values[j['tool'] as int],
      );
}

// ─── Screen ───────────────────────────────────────────────────────────────────

/// Full-featured PDF reader.
///
/// Renders each page as a JPEG image via pdfium (PdfDocument → PdfPage.render)
/// so it works on ALL Android devices including those using the Impeller/Vulkan
/// backend — which breaks PdfViewPinch's SurfaceProducer texture approach.
///
/// Features: pinch-zoom, page-flip / continuous scroll, auto-hiding chrome,
/// seek bar, go-to-page, bookmarks, highlight/underline/eraser marks
/// (persisted to SharedPreferences), night mode, brightness, share.
class PdfReaderScreen extends StatefulWidget {
  final String filePath;
  const PdfReaderScreen({super.key, required this.filePath});

  @override
  State<PdfReaderScreen> createState() => _PdfReaderScreenState();
}

class _PdfReaderScreenState extends State<PdfReaderScreen>
    with TickerProviderStateMixin {
  // ── Document ──────────────────────────────────────────────────────────────
  PdfDocument? _doc;
  int _totalPages = 0;
  final Map<int, Uint8List> _pageCache = {}; // page→JPEG bytes
  final Set<int> _rendering = {};

  // ── State ─────────────────────────────────────────────────────────────────
  int _currentPage = 1;
  String? _error;
  bool _usedFallback = false;
  String _textFallback = '';

  // ── Chrome auto-hide ──────────────────────────────────────────────────────
  bool _barsVisible = true;
  Timer? _autoHideTimer;
  late final AnimationController _barAnim;
  late final Animation<double> _barFade;

  // ── Zoom ──────────────────────────────────────────────────────────────────
  final TransformationController _transform = TransformationController();

  // ── Scroll (continuous mode) ──────────────────────────────────────────────
  late final PageController _pageCtrl;
  bool _horizontalMode = false;

  // ── Display ───────────────────────────────────────────────────────────────
  bool _nightMode = false;
  double _nightOpacity = 0.45;
  double _brightness = 1.0;
  bool _settingsOpen = false;

  // ── Bookmarks ─────────────────────────────────────────────────────────────
  final Set<int> _bookmarks = {};

  // ── Marks ─────────────────────────────────────────────────────────────────
  MarkTool _activeTool = MarkTool.none;
  final List<PdfMark> _marks = [];
  Offset? _dragStart, _dragCurrent;

  // ── Search ────────────────────────────────────────────────────────────────
  bool _searchMode = false;
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  // ── Prefs keys ────────────────────────────────────────────────────────────
  String get _bmKey => 'pdf_bm_${widget.filePath.hashCode}';
  String get _markKey => 'pdf_mk_${widget.filePath.hashCode}';
  String get _fileName => widget.filePath.split('/').last;

  // ── Render resolution ─────────────────────────────────────────────────────
  static const double _renderWidth = 1080.0;

  @override
  void initState() {
    super.initState();
    _barAnim = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 220), value: 1.0);
    _barFade = CurvedAnimation(parent: _barAnim, curve: Curves.easeOut);
    _pageCtrl = PageController(initialPage: 0);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _openDocument();
    _loadPrefs();
  }

  @override
  void dispose() {
    _autoHideTimer?.cancel();
    _barAnim.dispose();
    _transform.dispose();
    _pageCtrl.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _doc?.close();
    super.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  // ── Open document ─────────────────────────────────────────────────────────
  Future<void> _openDocument() async {
    final file = File(widget.filePath);
    if (!file.existsSync()) {
      _setError('File not found:\n${widget.filePath}');
      return;
    }
    try {
      final doc = await PdfDocument.openFile(widget.filePath);
      if (!mounted) return;
      setState(() {
        _doc = doc;
        _totalPages = doc.pagesCount;
      });
      // Render first two pages eagerly
      unawaited(_renderPage(1));
      if (doc.pagesCount > 1) unawaited(_renderPage(2));
      _scheduleAutoHide();
    } catch (e) {
      _tryTextFallback('$e');
    }
  }

  /// Renders [pageNum] (1-based) to JPEG bytes and caches them.
  Future<Uint8List?> _renderPage(int pageNum) async {
    if (_doc == null) return null;
    if (pageNum < 1 || pageNum > _totalPages) return null;
    if (_pageCache.containsKey(pageNum)) return _pageCache[pageNum];
    if (_rendering.contains(pageNum)) return null;
    _rendering.add(pageNum);
    try {
      final page = await _doc!.getPage(pageNum);
      final aspectRatio = page.height / page.width;
      final img = await page.render(
        width: _renderWidth,
        height: _renderWidth * aspectRatio,
        format: PdfPageImageFormat.jpeg,
        backgroundColor: '#FFFFFF',
        quality: 90,
      );
      await page.close();
      if (img == null || img.bytes.isEmpty) return null;
      final bytes = img.bytes;
      if (mounted) setState(() => _pageCache[pageNum] = bytes);
      return bytes;
    } catch (_) {
      return null;
    } finally {
      _rendering.remove(pageNum);
    }
  }

  void _preloadAround(int page) {
    for (int i = (page - 1).clamp(1, _totalPages);
        i <= (page + 2).clamp(1, _totalPages);
        i++) {
      unawaited(_renderPage(i));
    }
  }

  // ── Prefs ─────────────────────────────────────────────────────────────────
  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    final bm = p.getStringList(_bmKey) ?? [];
    final ms = p.getStringList(_markKey) ?? [];
    if (!mounted) return;
    setState(() {
      _bookmarks.addAll(bm.map((s) => int.tryParse(s) ?? 0).where((x) => x > 0));
      for (final raw in ms) {
        try { _marks.add(PdfMark.fromJson(jsonDecode(raw))); } catch (_) {}
      }
    });
  }

  Future<void> _saveBookmarks() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_bmKey, _bookmarks.map((x) => '$x').toList());
  }

  Future<void> _saveMarks() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_markKey, _marks.map((m) => jsonEncode(m.toJson())).toList());
  }

  // ── Bookmarks ─────────────────────────────────────────────────────────────
  void _toggleBookmark() {
    setState(() => _bookmarks.contains(_currentPage)
        ? _bookmarks.remove(_currentPage)
        : _bookmarks.add(_currentPage));
    _saveBookmarks();
    _toast(_bookmarks.contains(_currentPage)
        ? 'Bookmarked page $_currentPage' : 'Bookmark removed');
  }

  // ── Marks ─────────────────────────────────────────────────────────────────
  void _selectTool(MarkTool t) {
    setState(() => _activeTool = _activeTool == t ? MarkTool.none : t);
    _activeTool != MarkTool.none ? _autoHideTimer?.cancel() : _scheduleAutoHide();
  }

  void _onMarkEnd(DragEndDetails d) {
    if (_activeTool == MarkTool.none || _dragStart == null || _dragCurrent == null) return;
    final size = MediaQuery.of(context).size;
    Offset toFrac(Offset o) => Offset(
        (o.dx / size.width).clamp(0.0, 1.0),
        (o.dy / size.height).clamp(0.0, 1.0));
    if (_activeTool == MarkTool.eraser) {
      final r = Rect.fromPoints(toFrac(_dragStart!), toFrac(_dragCurrent!)).inflate(0.02);
      setState(() => _marks.removeWhere((m) =>
          m.page == _currentPage &&
          r.overlaps(Rect.fromPoints(m.start, m.end).inflate(0.01))));
    } else {
      setState(() => _marks.add(PdfMark(
          page: _currentPage,
          start: toFrac(_dragStart!),
          end: toFrac(_dragCurrent!),
          tool: _activeTool)));
    }
    _saveMarks();
    setState(() { _dragStart = null; _dragCurrent = null; });
  }

  // ── Chrome ────────────────────────────────────────────────────────────────
  void _onTap() {
    if (_settingsOpen) { setState(() => _settingsOpen = false); return; }
    if (_activeTool != MarkTool.none) return;
    _barsVisible ? _hideBars() : _showBars();
  }

  void _showBars() {
    _barAnim.forward();
    setState(() => _barsVisible = true);
    _scheduleAutoHide();
  }

  void _hideBars() {
    _barAnim.reverse();
    setState(() => _barsVisible = false);
  }

  void _scheduleAutoHide() {
    _autoHideTimer?.cancel();
    if (_activeTool != MarkTool.none || _settingsOpen) return;
    _autoHideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && !_settingsOpen) _hideBars();
    });
  }

  // ── Navigation ────────────────────────────────────────────────────────────
  void _goToPage(int page) {
    page = page.clamp(1, _totalPages);
    if (page == _currentPage) return;
    setState(() => _currentPage = page);
    _pageCtrl.animateToPage(page - 1,
        duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    _preloadAround(page);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  void _toast(String msg) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.only(bottom: 80, left: 24, right: 24),
    ));
  }

  void _setError(String msg) {
    if (mounted) setState(() => _error = msg);
  }

  void _tryTextFallback(String reason) {
    final text = DocConverter.extractPdfText(widget.filePath);
    if (text != null && text.trim().isNotEmpty) {
      if (mounted) setState(() { _textFallback = text; _usedFallback = true; });
    } else {
      _setError('Cannot open this PDF.\n$reason');
    }
  }

  Future<void> _share() async {
    final ok = await ShareService.share([widget.filePath]);
    if (!ok && mounted) _toast('Could not share file');
  }

  void _restartInMode(bool horizontal) {
    setState(() {
      _horizontalMode = horizontal;
      _pageCache.clear();
      _rendering.clear();
    });
    _doc?.close().then((_) { _doc = null; _openDocument(); });
  }

  // ── Search helpers ────────────────────────────────────────────────────────

  void _openSearch() {
    setState(() => _searchMode = true);
    _autoHideTimer?.cancel();
    _showBars();
    Future.microtask(() => _searchFocus.requestFocus());
  }

  void _closeSearch() {
    setState(() => _searchMode = false);
    _searchCtrl.clear();
    _searchFocus.unfocus();
    _scheduleAutoHide();
  }

  /// Rough estimate: average PDF page is ~3 000 characters.
  static const int _charsPerPage = 3000;

  void _runSearch(String query) {
    if (query.trim().isEmpty) return;
    _searchFocus.unfocus();

    final rawText = DocConverter.extractPdfText(widget.filePath);
    if (rawText == null || rawText.trim().isEmpty) {
      _toast('No text found in this PDF');
      return;
    }

    final q = query.toLowerCase();
    final text = rawText;
    final results = <_SearchResult>[];
    final lines = text.split(RegExp(r'\r?\n'));

    // Walk through lines and collect every line (or pair) containing the query.
    int charOffset = 0;
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.toLowerCase().contains(q)) {
        // Build a 2-line context snippet.
        final prev = i > 0 ? lines[i - 1].trim() : '';
        final curr = line.trim();
        final next = i + 1 < lines.length ? lines[i + 1].trim() : '';
        final snippet = [if (prev.isNotEmpty) prev, curr, if (next.isNotEmpty) next]
            .join('\n');
        final pageEstimate = ((charOffset / _charsPerPage) + 1).round()
            .clamp(1, _totalPages > 0 ? _totalPages : 9999);
        results.add(_SearchResult(
          snippet: snippet,
          charOffset: charOffset,
          pageEstimate: pageEstimate,
          matchLine: curr,
          query: query,
        ));
      }
      charOffset += line.length + 1; // +1 for the newline
    }

    if (results.isEmpty) {
      _toast('No results for "$query"');
      return;
    }

    _showSearchResults(query, results);
  }

  void _showSearchResults(String query, List<_SearchResult> results) {
    _autoHideTimer?.cancel();
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.55,
          minChildSize: 0.3,
          maxChildSize: 0.85,
          builder: (_, scrollCtrl) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Handle
                Center(
                  child: Container(
                    width: 40, height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                // Header
                Row(children: [
                  const Icon(Icons.search, color: Colors.lightBlueAccent, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '"$query" — ${results.length} result${results.length == 1 ? '' : 's'}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView.separated(
                    controller: scrollCtrl,
                    itemCount: results.length,
                    separatorBuilder: (_, __) =>
                        const Divider(color: Colors.white12, height: 1),
                    itemBuilder: (ctx, i) {
                      final r = results[i];
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 4),
                        leading: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.lightBlueAccent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            'p.${r.pageEstimate}',
                            style: const TextStyle(
                                color: Colors.lightBlueAccent,
                                fontSize: 11,
                                fontWeight: FontWeight.w700),
                          ),
                        ),
                        title: _buildSnippetText(r.snippet, r.query),
                        onTap: () {
                          Navigator.pop(ctx);
                          _closeSearch();
                          _goToPage(r.pageEstimate);
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ).then((_) => _scheduleAutoHide());
  }

  /// Renders a snippet with the query terms highlighted in amber.
  Widget _buildSnippetText(String snippet, String query) {
    final q = query.toLowerCase();
    final spans = <TextSpan>[];
    int start = 0;
    String lower = snippet.toLowerCase();
    while (true) {
      final idx = lower.indexOf(q, start);
      if (idx == -1) {
        spans.add(TextSpan(
            text: snippet.substring(start),
            style: const TextStyle(color: Colors.white60, fontSize: 12)));
        break;
      }
      if (idx > start) {
        spans.add(TextSpan(
            text: snippet.substring(start, idx),
            style: const TextStyle(color: Colors.white60, fontSize: 12)));
      }
      spans.add(TextSpan(
          text: snippet.substring(idx, idx + query.length),
          style: const TextStyle(
              color: Colors.amber,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              backgroundColor: Color(0x33E5C07B))));
      start = idx + query.length;
    }
    return Text.rich(TextSpan(children: spans),
        maxLines: 3, overflow: TextOverflow.ellipsis);
  }

  // ─── BUILD ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_error != null) return _buildError();
    if (_usedFallback) return _buildTextFallback();

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── Page viewer ─────────────────────────────────────────────────
          _buildPageView(),

          // ── Mark gesture layer ──────────────────────────────────────────
          if (_activeTool != MarkTool.none)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (d) => setState(() {
                  _dragStart = d.localPosition;
                  _dragCurrent = d.localPosition;
                }),
                onPanUpdate: (d) => setState(() => _dragCurrent = d.localPosition),
                onPanEnd: _onMarkEnd,
                child: CustomPaint(
                  painter: _LiveMarkPainter(
                    dragStart: _dragStart,
                    dragCurrent: _dragCurrent,
                    tool: _activeTool,
                  ),
                ),
              ),
            ),

          // ── Persisted marks for current page ───────────────────────────
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _SavedMarkPainter(
                  marks: _marks.where((m) => m.page == _currentPage).toList(),
                ),
              ),
            ),
          ),

          // ── Night overlay ───────────────────────────────────────────────
          if (_nightMode)
            IgnorePointer(
                child: Container(
                    color: Colors.black.withValues(alpha: _nightOpacity))),

          // ── Brightness overlay ──────────────────────────────────────────
          if (_brightness < 1.0)
            IgnorePointer(
                child: Container(
                    color: Colors.white
                        .withValues(alpha: (1.0 - _brightness) * 0.6))),

          // ── Tap to toggle chrome ────────────────────────────────────────
          if (_activeTool == MarkTool.none)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _onTap,
              ),
            ),

          // ── Top bar ─────────────────────────────────────────────────────
          Positioned(
            top: 0, left: 0, right: 0,
            child: FadeTransition(opacity: _barFade, child: _buildTopBar()),
          ),

          // ── Bottom bar ──────────────────────────────────────────────────
          if (_totalPages > 0)
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: FadeTransition(opacity: _barFade, child: _buildBottomBar()),
            ),

          // ── Page pill ───────────────────────────────────────────────────
          if (_totalPages > 0)
            Positioned(
              bottom: _barsVisible ? 88 : 16,
              right: 16,
              child: AnimatedOpacity(
                opacity: _barsVisible ? 0.0 : 1.0,
                duration: const Duration(milliseconds: 200),
                child: _buildPagePill(),
              ),
            ),

          // ── Marking hint ────────────────────────────────────────────────
          if (_activeTool != MarkTool.none)
            Positioned(
              bottom: 32, left: 16,
              child: _buildMarkHint(),
            ),

          // ── Settings panel ──────────────────────────────────────────────
          if (_settingsOpen)
            Positioned(
                bottom: 0, left: 0, right: 0,
                child: _buildSettings()),
        ],
      ),
    );
  }

  // ── Page view ─────────────────────────────────────────────────────────────
  Widget _buildPageView() {
    if (_doc == null) {
      return const Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        CircularProgressIndicator(color: Colors.white70),
        SizedBox(height: 12),
        Text('Loading PDF…', style: TextStyle(color: Colors.white54)),
      ]));
    }

    return InteractiveViewer(
      transformationController: _transform,
      minScale: 1.0,
      maxScale: 8.0,
      panEnabled: true,
      child: PageView.builder(
        controller: _pageCtrl,
        scrollDirection: _horizontalMode ? Axis.horizontal : Axis.vertical,
        physics: _activeTool != MarkTool.none
            ? const NeverScrollableScrollPhysics()
            : const PageScrollPhysics(),
        itemCount: _totalPages,
        onPageChanged: (idx) {
          setState(() => _currentPage = idx + 1);
          _preloadAround(idx + 1);
          _showBars();
        },
        itemBuilder: (ctx, idx) => _buildPageTile(idx + 1),
      ),
    );
  }

  Widget _buildPageTile(int pageNum) {
    final bytes = _pageCache[pageNum];
    if (bytes != null) {
      return Container(
        color: const Color(0xFF1A1A1A),
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Image.memory(
          bytes,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
          gaplessPlayback: true,
        ),
      );
    }
    // Not yet rendered — trigger render and show loader
    unawaited(_renderPage(pageNum));
    return Container(
      color: const Color(0xFF1A1A1A),
      child: const Center(
        child: CircularProgressIndicator(
            color: Colors.white54, strokeWidth: 2),
      ),
    );
  }

  // ── Top bar ───────────────────────────────────────────────────────────────
  Widget _buildTopBar() {
    final isBookmarked = _bookmarks.contains(_currentPage);
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [Color(0xD8000000), Colors.transparent],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => Navigator.pop(context),
              ),
              Expanded(
                child: _searchMode
                    ? TextField(
                        controller: _searchCtrl,
                        focusNode: _searchFocus,
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                        cursorColor: Colors.white,
                        decoration: InputDecoration(
                          hintText: 'Search in PDF…',
                          hintStyle: const TextStyle(color: Colors.white54),
                          border: InputBorder.none,
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.close, color: Colors.white70, size: 18),
                            onPressed: _closeSearch,
                          ),
                        ),
                        textInputAction: TextInputAction.search,
                        onSubmitted: _runSearch,
                      )
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_fileName,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600),
                              overflow: TextOverflow.ellipsis),
                        ],
                      ),
              ),
              // Marking tools
              _toolBtn(Icons.highlight, MarkTool.highlight, Colors.yellow, 'Highlight'),
              _toolBtn(Icons.format_underline, MarkTool.underline, Colors.redAccent, 'Underline'),
              _toolBtn(Icons.auto_fix_high, MarkTool.eraser, Colors.white70, 'Eraser'),
              // Bookmark
              IconButton(
                icon: Icon(
                    isBookmarked ? Icons.bookmark : Icons.bookmark_border,
                    color: isBookmarked ? Colors.amber : Colors.white),
                onPressed: _toggleBookmark,
              ),
              if (_bookmarks.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.list, color: Colors.white),
                  onPressed: _showBookmarksList,
                ),
              IconButton(
                icon: const Icon(Icons.search, color: Colors.white),
                tooltip: 'Search text',
                onPressed: _openSearch,
              ),
              IconButton(
                icon: const Icon(Icons.find_in_page_outlined, color: Colors.white),
                onPressed: _totalPages > 1 ? _showGoToPageDialog : null,
              ),
              IconButton(
                icon: const Icon(Icons.share_outlined, color: Colors.white),
                onPressed: _share,
              ),
              IconButton(
                icon: const Icon(Icons.tune, color: Colors.white),
                onPressed: () {
                  setState(() => _settingsOpen = !_settingsOpen);
                  _autoHideTimer?.cancel();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolBtn(IconData icon, MarkTool tool, Color color, String tip) {
    final active = _activeTool == tool;
    return Tooltip(
      message: tip,
      child: GestureDetector(
        onTap: () => _selectTool(tool),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 2),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: active ? color.withValues(alpha: 0.25) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: active ? Border.all(color: color, width: 1.5) : null,
          ),
          child: Icon(icon, color: active ? color : Colors.white60, size: 20),
        ),
      ),
    );
  }

  // ── Bottom bar ────────────────────────────────────────────────────────────
  Widget _buildBottomBar() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter, end: Alignment.topCenter,
          colors: [Color(0xD8000000), Colors.transparent],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            _navBtn(Icons.chevron_left, _currentPage > 1,
                () => _goToPage(_currentPage - 1)),
            GestureDetector(
              onTap: _showGoToPageDialog,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(12)),
                child: Text('$_currentPage / $_totalPages',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderThemeData(
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                  trackHeight: 2.5,
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: Colors.white30,
                  thumbColor: Colors.white,
                  overlayColor: Colors.white24,
                ),
                child: Slider(
                  value: _currentPage.toDouble().clamp(1, _totalPages.toDouble()),
                  min: 1, max: _totalPages.toDouble(),
                  divisions: _totalPages > 1 ? _totalPages - 1 : 1,
                  onChanged: (v) => setState(() => _currentPage = v.round()),
                  onChangeEnd: (v) => _goToPage(v.round()),
                ),
              ),
            ),
            _navBtn(Icons.chevron_right, _currentPage < _totalPages,
                () => _goToPage(_currentPage + 1)),
            IconButton(
              icon: Icon(
                  _horizontalMode ? Icons.swap_vert : Icons.swap_horiz,
                  color: Colors.white70, size: 20),
              tooltip: _horizontalMode ? 'Vertical scroll' : 'Page flip',
              onPressed: () => _restartInMode(!_horizontalMode),
            ),
            if (_marks.any((m) => m.page == _currentPage))
              IconButton(
                icon: const Icon(Icons.layers_clear, color: Colors.white60, size: 20),
                tooltip: 'Clear marks on this page',
                onPressed: () {
                  setState(() => _marks.removeWhere((m) => m.page == _currentPage));
                  _saveMarks();
                  _toast('Marks cleared');
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _navBtn(IconData icon, bool enabled, VoidCallback onTap) =>
      IconButton(
        icon: Icon(icon, color: enabled ? Colors.white : Colors.white30),
        onPressed: enabled ? onTap : null,
        padding: const EdgeInsets.all(4),
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      );

  // ── Page pill ─────────────────────────────────────────────────────────────
  Widget _buildPagePill() {
    final bm = _bookmarks.contains(_currentPage);
    final mk = _marks.any((m) => m.page == _currentPage);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (bm) ...[
          const Icon(Icons.bookmark, color: Colors.amber, size: 12),
          const SizedBox(width: 4)
        ],
        if (mk) ...[
          const Icon(Icons.highlight, color: Colors.yellow, size: 12),
          const SizedBox(width: 4)
        ],
        Text('$_currentPage / $_totalPages',
            style: const TextStyle(
                color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
      ]),
    );
  }

  Widget _buildMarkHint() {
    final (label, color) = switch (_activeTool) {
      MarkTool.highlight => ('Highlight mode — drag to mark', Colors.yellow),
      MarkTool.underline => ('Underline mode — drag to mark', Colors.redAccent),
      MarkTool.eraser => ('Eraser — drag to erase', Colors.white70),
      MarkTool.none => ('', Colors.white),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.gesture, color: color, size: 14),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(color: color, fontSize: 11)),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: () => _selectTool(MarkTool.none),
          child: const Icon(Icons.close, color: Colors.white54, size: 14),
        ),
      ]),
    );
  }

  // ── Settings ──────────────────────────────────────────────────────────────
  Widget _buildSettings() {
    return GestureDetector(
      onTap: () {},
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xF0121212),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 16,
                offset: const Offset(0, -4))
          ],
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                  width: 40, height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2))),
            ),
            const Text('Display',
                style: TextStyle(
                    color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            Row(children: [
              const Icon(Icons.nights_stay_outlined, color: Colors.white70, size: 20),
              const SizedBox(width: 10),
              const Expanded(
                  child: Text('Night mode', style: TextStyle(color: Colors.white70))),
              Switch(
                value: _nightMode,
                onChanged: (v) => setState(() => _nightMode = v),
                activeThumbColor: Colors.amber,
                activeTrackColor: Colors.amber.withValues(alpha: 0.5),
              ),
            ]),
            if (_nightMode) ...[
              Row(children: [
                const SizedBox(width: 30),
                const Icon(Icons.brightness_3, color: Colors.white38, size: 16),
                Expanded(
                  child: Slider(
                    value: _nightOpacity, min: 0.1, max: 0.8, divisions: 14,
                    activeColor: Colors.amber, inactiveColor: Colors.white24,
                    onChanged: (v) => setState(() => _nightOpacity = v),
                  ),
                ),
                const Icon(Icons.brightness_2, color: Colors.white70, size: 16),
              ]),
            ],
            const SizedBox(height: 8),
            Row(children: [
              const Icon(Icons.brightness_medium_outlined, color: Colors.white70, size: 20),
              const SizedBox(width: 10),
              const Text('Brightness', style: TextStyle(color: Colors.white70)),
              Expanded(
                child: Slider(
                  value: _brightness, min: 0.2, max: 1.0, divisions: 16,
                  activeColor: Colors.white, inactiveColor: Colors.white24,
                  onChanged: (v) => setState(() => _brightness = v),
                ),
              ),
              const Icon(Icons.wb_sunny_outlined, color: Colors.white70, size: 16),
            ]),
            const Divider(color: Colors.white12, height: 24),
            Row(children: [
              Icon(_horizontalMode ? Icons.swap_horiz : Icons.swap_vert,
                  color: Colors.white70, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                    _horizontalMode ? 'Page-flip (horizontal)' : 'Continuous scroll (vertical)',
                    style: const TextStyle(color: Colors.white70)),
              ),
              TextButton(
                onPressed: () {
                  setState(() => _settingsOpen = false);
                  _restartInMode(!_horizontalMode);
                },
                child: const Text('Switch',
                    style: TextStyle(color: Colors.lightBlueAccent)),
              ),
            ]),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => setState(() => _settingsOpen = false),
                child: const Text('Close', style: TextStyle(color: Colors.white60)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Dialogs ───────────────────────────────────────────────────────────────
  void _showGoToPageDialog() {
    _autoHideTimer?.cancel();
    final tec = TextEditingController(text: '$_currentPage');
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Go to page', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: tec,
          style: const TextStyle(color: Colors.white),
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            hintText: '1 – $_totalPages',
            hintStyle: const TextStyle(color: Colors.white38),
            enabledBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: Colors.white24)),
            focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: Colors.lightBlueAccent)),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: Colors.white54))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.lightBlueAccent),
            onPressed: () {
              final p = int.tryParse(tec.text);
              if (p != null) _goToPage(p);
              Navigator.pop(context);
            },
            child: const Text('Go'),
          ),
        ],
      ),
    ).then((_) => _scheduleAutoHide());
  }

  void _showBookmarksList() {
    _autoHideTimer?.cancel();
    final sorted = _bookmarks.toList()..sort();
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Bookmarks',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            if (sorted.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: Text('No bookmarks yet',
                    style: TextStyle(color: Colors.white38))))
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: sorted.length,
                  itemBuilder: (ctx, i) {
                    final pg = sorted[i];
                    return ListTile(
                      leading: const Icon(Icons.bookmark, color: Colors.amber, size: 20),
                      title: Text('Page $pg',
                          style: const TextStyle(color: Colors.white)),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline,
                            color: Colors.white38, size: 18),
                        onPressed: () {
                          setState(() => _bookmarks.remove(pg));
                          _saveBookmarks();
                          Navigator.pop(context);
                        },
                      ),
                      onTap: () { _goToPage(pg); Navigator.pop(context); },
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    ).then((_) => _scheduleAutoHide());
  }

  // ── Error / Fallback ──────────────────────────────────────────────────────
  Widget _buildError() => Scaffold(
        backgroundColor: const Color(0xFF0F0F0F),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
          title: Text(_fileName,
              style: const TextStyle(fontSize: 14, color: Colors.white),
              overflow: TextOverflow.ellipsis),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.picture_as_pdf, size: 72, color: Colors.red),
              const SizedBox(height: 20),
              const Text('Cannot open PDF',
                  style: TextStyle(color: Colors.white, fontSize: 18,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              Text(_error!,
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                  textAlign: TextAlign.center),
            ]),
          ),
        ),
      );

  Widget _buildTextFallback() => Scaffold(
        backgroundColor: const Color(0xFF0F0F0F),
        appBar: AppBar(
          backgroundColor: const Color(0xFF1A1A1A),
          foregroundColor: Colors.white,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_fileName,
                  style: const TextStyle(fontSize: 14, color: Colors.white),
                  overflow: TextOverflow.ellipsis),
              const Text('Text view',
                  style: TextStyle(fontSize: 10, color: Colors.white38)),
            ],
          ),
          actions: [
            IconButton(
                icon: const Icon(Icons.share_outlined, color: Colors.white),
                onPressed: _share),
          ],
        ),
        body: Column(children: [
          Container(
            color: Colors.amber.withValues(alpha: 0.12),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: const Row(children: [
              Icon(Icons.info_outline, size: 15, color: Colors.amber),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                    'Graphical rendering unavailable — showing extracted text.',
                    style: TextStyle(color: Colors.amber, fontSize: 11)),
              ),
            ]),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(18),
              child: SelectableText(_textFallback,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 15, height: 1.7)),
            ),
          ),
        ]),
      );
}

// ─── Mark painters ───────────────────────────────────────────────────────────

/// Draws the in-progress drag stroke (live feedback while dragging).
class _LiveMarkPainter extends CustomPainter {
  final Offset? dragStart, dragCurrent;
  final MarkTool tool;
  const _LiveMarkPainter(
      {required this.dragStart,
      required this.dragCurrent,
      required this.tool});

  @override
  void paint(Canvas canvas, Size size) {
    if (dragStart == null || dragCurrent == null) return;
    if (tool == MarkTool.highlight) {
      canvas.drawRect(
          Rect.fromPoints(dragStart!, dragCurrent!),
          Paint()
            ..color = Colors.yellow.withValues(alpha: 0.4)
            ..style = PaintingStyle.fill);
    } else if (tool == MarkTool.underline) {
      final y = (dragStart!.dy + dragCurrent!.dy) / 2 + 14;
      canvas.drawLine(Offset(dragStart!.dx, y), Offset(dragCurrent!.dx, y),
          Paint()
            ..color = Colors.redAccent.withValues(alpha: 0.9)
            ..strokeWidth = 2.5);
    } else if (tool == MarkTool.eraser) {
      canvas.drawRect(
          Rect.fromPoints(dragStart!, dragCurrent!),
          Paint()
            ..color = Colors.white.withValues(alpha: 0.15)
            ..style = PaintingStyle.fill);
    }
  }

  @override
  bool shouldRepaint(_LiveMarkPainter old) =>
      old.dragStart != dragStart ||
      old.dragCurrent != dragCurrent ||
      old.tool != tool;
}

/// Draws persisted marks for the current page (fractional → screen coords).
class _SavedMarkPainter extends CustomPainter {
  final List<PdfMark> marks;
  const _SavedMarkPainter({required this.marks});

  @override
  void paint(Canvas canvas, Size size) {
    for (final m in marks) {
      final sx = m.start.dx * size.width;
      final ex = m.end.dx * size.width;
      final sy = m.start.dy * size.height;
      final ey = m.end.dy * size.height;
      if (m.tool == MarkTool.highlight) {
        canvas.drawRect(
            Rect.fromLTRB(sx, sy - 2, ex, ey + 2),
            Paint()
              ..color = Colors.yellow.withValues(alpha: 0.35)
              ..style = PaintingStyle.fill);
      } else if (m.tool == MarkTool.underline) {
        final y = (sy + ey) / 2 + 14;
        canvas.drawLine(Offset(sx, y), Offset(ex, y),
            Paint()
              ..color = Colors.redAccent.withValues(alpha: 0.9)
              ..strokeWidth = 2.5);
      }
    }
  }

  @override
  bool shouldRepaint(_SavedMarkPainter old) => old.marks != marks;
}

/// A single search result from text search across PDF pages.
class _SearchResult {
  final String snippet;
  final int charOffset;
  final int pageEstimate;
  final String matchLine;
  final String query;

  _SearchResult({
    required this.snippet,
    required this.charOffset,
    required this.pageEstimate,
    required this.matchLine,
    required this.query,
  });
}
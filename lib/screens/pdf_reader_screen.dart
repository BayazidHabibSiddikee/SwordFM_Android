import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfx/pdfx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/doc_converter.dart';
import '../services/share_service.dart';

// ── Highlight model ────────────────────────────────────────────────────────────

enum MarkTool { none, highlight, underline, eraser }

/// A single drawn mark on one PDF page, stored as fractional coordinates
/// (0–1) relative to the rendered page rect so they survive zoom changes.
class PdfMark {
  final int page;
  final Offset start; // fraction of page rect
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
        'sx': start.dx,
        'sy': start.dy,
        'ex': end.dx,
        'ey': end.dy,
        'tool': tool.index,
      };

  factory PdfMark.fromJson(Map<String, dynamic> j) => PdfMark(
        page: j['page'] as int,
        start: Offset((j['sx'] as num).toDouble(), (j['sy'] as num).toDouble()),
        end: Offset((j['ex'] as num).toDouble(), (j['ey'] as num).toDouble()),
        tool: MarkTool.values[j['tool'] as int],
      );
}

// ── Main screen ────────────────────────────────────────────────────────────────

/// A full-featured PDF reader modelled after Adobe Acrobat / WPS PDF.
///
/// Features:
/// • pdfium rendering via PdfViewPinch — always fills screen width, zoom in/out
/// • Auto-hiding top toolbar + bottom bar (tap to toggle)
/// • Floating page-number pill (always visible when chrome is hidden)
/// • Bottom seek-bar — drag to jump to any page
/// • Vertical continuous  ↔  horizontal page-flip toggle
/// • Night mode + brightness slider
/// • Jump-to-page dialog
/// • Bookmarks — persisted per-file in SharedPreferences
/// • Highlight / Underline / Eraser marking tools — drawn as overlays,
///   persisted per-file in SharedPreferences
/// • Share button
/// • Text fallback for encrypted/unrenderable PDFs
class PdfReaderScreen extends StatefulWidget {
  final String filePath;
  const PdfReaderScreen({super.key, required this.filePath});

  @override
  State<PdfReaderScreen> createState() => _PdfReaderScreenState();
}

class _PdfReaderScreenState extends State<PdfReaderScreen>
    with TickerProviderStateMixin {
  // ── PDF controller ──────────────────────────────────────────────────────────
  PdfControllerPinch? _controller;
  bool _docErrorHandled = false;

  // ── State ───────────────────────────────────────────────────────────────────
  int _currentPage = 1;
  int _totalPages = 0;
  String? _error;
  bool _usedFallback = false;
  String _textFallback = '';

  // ── UI chrome visibility ────────────────────────────────────────────────────
  bool _barsVisible = true;
  Timer? _autoHideTimer;
  late final AnimationController _barAnim;
  late final Animation<double> _barFade;

  // ── Display settings ────────────────────────────────────────────────────────
  bool _nightMode = false;
  double _nightOpacity = 0.45;
  double _brightness = 1.0;
  bool _horizontalMode = false;

  // ── Bookmarks ───────────────────────────────────────────────────────────────
  final Set<int> _bookmarks = {};

  // ── Marking / highlight ─────────────────────────────────────────────────────
  MarkTool _activeTool = MarkTool.none;
  final List<PdfMark> _marks = [];
  // In-progress stroke being drawn right now
  Offset? _dragStart;
  Offset? _dragCurrent;

  // ── Bottom settings panel ───────────────────────────────────────────────────
  bool _settingsOpen = false;

  // ── Prefs keys ──────────────────────────────────────────────────────────────
  String get _bookmarksKey => 'pdf_bookmarks_${widget.filePath.hashCode}';
  String get _marksKey => 'pdf_marks_${widget.filePath.hashCode}';
  String get _fileName => widget.filePath.split('/').last;

  // ── Init ────────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _barAnim = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 220),
        value: 1.0);
    _barFade = CurvedAnimation(parent: _barAnim, curve: Curves.easeOut);
    _initPdf();
    _loadPrefs();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    _autoHideTimer?.cancel();
    _controller?.dispose();
    _barAnim.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // ── PDF init ────────────────────────────────────────────────────────────────
  void _initPdf() {
    if (!File(widget.filePath).existsSync()) {
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => _setError('File not found:\n${widget.filePath}'));
      return;
    }
    try {
      _controller = PdfControllerPinch(
        document: PdfDocument.openFile(widget.filePath),
        initialPage: 1,
      );
    } catch (e) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _tryTextFallback('$e'));
    }
  }

  void _setError(String msg) {
    if (mounted) setState(() => _error = msg);
  }

  void _tryTextFallback(String reason) {
    if (_docErrorHandled) return;
    _docErrorHandled = true;
    final text = DocConverter.extractPdfText(widget.filePath);
    if (text != null && text.trim().isNotEmpty) {
      if (mounted) {
        setState(() {
          _textFallback = text;
          _usedFallback = true;
        });
      }
    } else {
      _setError('Cannot render this PDF.\n$reason');
    }
  }

  // ── Prefs persistence ───────────────────────────────────────────────────────
  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    // bookmarks
    final bm = prefs.getStringList(_bookmarksKey) ?? [];
    // marks
    final ms = prefs.getStringList(_marksKey) ?? [];
    if (mounted) {
      setState(() {
        _bookmarks.addAll(
            bm.map((s) => int.tryParse(s) ?? 0).where((p) => p > 0));
        for (final raw in ms) {
          try {
            _marks.add(PdfMark.fromJson(
                jsonDecode(raw) as Map<String, dynamic>));
          } catch (_) {}
        }
      });
    }
  }

  Future<void> _saveBookmarks() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _bookmarksKey, _bookmarks.map((p) => '$p').toList());
  }

  Future<void> _saveMarks() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _marksKey, _marks.map((m) => jsonEncode(m.toJson())).toList());
  }

  // ── Bookmarks ───────────────────────────────────────────────────────────────
  void _toggleBookmark() {
    setState(() {
      if (_bookmarks.contains(_currentPage)) {
        _bookmarks.remove(_currentPage);
      } else {
        _bookmarks.add(_currentPage);
      }
    });
    _saveBookmarks();
    _showToast(_bookmarks.contains(_currentPage)
        ? 'Bookmarked page $_currentPage'
        : 'Bookmark removed');
  }

  // ── Bars auto-hide ──────────────────────────────────────────────────────────
  void _onTap() {
    if (_settingsOpen) {
      setState(() => _settingsOpen = false);
      return;
    }
    // If a marking tool is active, tapping should not toggle bars
    if (_activeTool != MarkTool.none) return;
    _toggleBars();
  }

  void _toggleBars() {
    _autoHideTimer?.cancel();
    if (_barsVisible) {
      _barAnim.reverse();
      setState(() => _barsVisible = false);
    } else {
      _barAnim.forward();
      setState(() => _barsVisible = true);
      _scheduleAutoHide();
    }
  }

  void _showBars() {
    if (!_barsVisible) {
      _barAnim.forward();
      setState(() => _barsVisible = true);
    }
    _scheduleAutoHide();
  }

  void _scheduleAutoHide() {
    _autoHideTimer?.cancel();
    if (_activeTool != MarkTool.none) return; // keep bars while marking
    _autoHideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && !_settingsOpen && _activeTool == MarkTool.none) {
        _barAnim.reverse();
        setState(() => _barsVisible = false);
      }
    });
  }

  // ── Navigation ──────────────────────────────────────────────────────────────
  void _goToPage(int page) {
    if (page < 1 || page > _totalPages || _controller == null) return;
    _controller!.animateToPage(
      pageNumber: page,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
    setState(() => _currentPage = page);
  }

  // ── Marking ─────────────────────────────────────────────────────────────────
  void _selectTool(MarkTool tool) {
    setState(() => _activeTool = _activeTool == tool ? MarkTool.none : tool);
    if (_activeTool != MarkTool.none) {
      _autoHideTimer?.cancel();
      _showBars(); // keep bars visible while marking
    } else {
      _scheduleAutoHide();
    }
  }

  /// Convert a screen-space offset into fractional page coordinates.
  /// Returns null if the page rect is not available yet.
  Offset? _screenToPage(Offset screenPos, int pageNum) {
    if (_controller == null) return null;
    try {
      final pageRect = _controller!.getPageRect(pageNum);
      if (pageRect == null) return null;
      final zoom = _controller!.zoomRatio;
      final view = _controller!.viewRect;
      // Screen pos → doc pos → page-relative fraction
      final docX = (screenPos.dx + view.left) / zoom;
      final docY = (screenPos.dy + view.top) / zoom;
      final fx = (docX - pageRect.left) / pageRect.width;
      final fy = (docY - pageRect.top) / pageRect.height;
      return Offset(fx.clamp(0.0, 1.0), fy.clamp(0.0, 1.0));
    } catch (_) {
      return null;
    }
  }

  void _onMarkStart(DragStartDetails d) {
    if (_activeTool == MarkTool.none) return;
    setState(() {
      _dragStart = d.localPosition;
      _dragCurrent = d.localPosition;
    });
  }

  void _onMarkUpdate(DragUpdateDetails d) {
    if (_activeTool == MarkTool.none) return;
    setState(() => _dragCurrent = d.localPosition);
  }

  void _onMarkEnd(DragEndDetails d) {
    if (_activeTool == MarkTool.none ||
        _dragStart == null ||
        _dragCurrent == null) return;

    if (_activeTool == MarkTool.eraser) {
      _eraseAt(_dragStart!, _dragCurrent!);
    } else {
      final startFrac = _screenToPage(_dragStart!, _currentPage);
      final endFrac = _screenToPage(_dragCurrent!, _currentPage);
      if (startFrac != null && endFrac != null) {
        setState(() {
          _marks.add(PdfMark(
            page: _currentPage,
            start: startFrac,
            end: endFrac,
            tool: _activeTool,
          ));
        });
        _saveMarks();
      }
    }
    setState(() {
      _dragStart = null;
      _dragCurrent = null;
    });
  }

  void _eraseAt(Offset start, Offset end) {
    final startFrac = _screenToPage(start, _currentPage);
    final endFrac = _screenToPage(end, _currentPage);
    if (startFrac == null || endFrac == null) return;
    final eraseRect = Rect.fromPoints(startFrac, endFrac).inflate(0.02);
    setState(() {
      _marks.removeWhere((m) {
        if (m.page != _currentPage) return false;
        return eraseRect.overlaps(Rect.fromPoints(m.start, m.end).inflate(0.005));
      });
    });
    _saveMarks();
  }

  void _clearPageMarks() {
    setState(() => _marks.removeWhere((m) => m.page == _currentPage));
    _saveMarks();
    _showToast('Marks cleared on page $_currentPage');
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────
  void _showToast(String msg) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.only(bottom: 80, left: 24, right: 24),
    ));
  }

  Future<void> _share() async {
    final ok = await ShareService.share([widget.filePath]);
    if (!ok && mounted) _showToast('Could not share this file');
  }

  void _toggleScrollMode() {
    final page = _currentPage;
    final ctrl = PdfControllerPinch(
      document: PdfDocument.openFile(widget.filePath),
      initialPage: page,
    );
    _controller?.dispose();
    setState(() {
      _horizontalMode = !_horizontalMode;
      _controller = ctrl;
    });
    _showToast(_horizontalMode ? 'Page-flip mode' : 'Continuous scroll mode');
  }

  // ── Build ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_error != null) return _buildError(cs);
    if (_usedFallback) return _buildTextFallback(cs);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── PDF + mark gesture layer ───────────────────────────────────────
          _buildPdfWithMarking(),

          // ── Night overlay ──────────────────────────────────────────────────
          if (_nightMode)
            IgnorePointer(
              child: Container(
                  color: Colors.black.withValues(alpha: _nightOpacity)),
            ),

          // ── Brightness overlay ─────────────────────────────────────────────
          if (_brightness < 1.0)
            IgnorePointer(
              child: Container(
                  color: Colors.white
                      .withValues(alpha: (1.0 - _brightness) * 0.6)),
            ),

          // ── Global tap to toggle bars ──────────────────────────────────────
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _onTap,
            ),
          ),

          // ── Top toolbar ────────────────────────────────────────────────────
          if (_controller != null)
            Positioned(
              top: 0, left: 0, right: 0,
              child: FadeTransition(
                  opacity: _barFade, child: _buildTopBar(cs)),
            ),

          // ── Bottom bar ─────────────────────────────────────────────────────
          if (_controller != null && _totalPages > 0)
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: FadeTransition(
                  opacity: _barFade, child: _buildBottomBar(cs)),
            ),

          // ── Page pill (shown when bars hidden) ─────────────────────────────
          if (_totalPages > 0 && _controller != null)
            Positioned(
              bottom: _barsVisible ? 88 : 16,
              right: 16,
              child: AnimatedOpacity(
                opacity: _barsVisible ? 0.0 : 1.0,
                duration: const Duration(milliseconds: 200),
                child: _buildPagePill(),
              ),
            ),

          // ── Marking toolbar (shown when tool active) ───────────────────────
          if (_activeTool != MarkTool.none)
            Positioned(
              bottom: _barsVisible ? 88 : 24,
              left: 16,
              child: _buildMarkingHint(),
            ),

          // ── Settings panel ─────────────────────────────────────────────────
          if (_settingsOpen)
            Positioned(
                bottom: 0, left: 0, right: 0,
                child: _buildSettingsPanel(cs)),
        ],
      ),
    );
  }

  // ── PDF + marking overlay ─────────────────────────────────────────────────
  Widget _buildPdfWithMarking() {
    return Stack(
      children: [
        // PDF view — minScale: 1.0 keeps page always filling screen width
        PdfViewPinch(
          controller: _controller!,
          scrollDirection:
              _horizontalMode ? Axis.horizontal : Axis.vertical,
          padding: _horizontalMode ? 0 : 6,
          minScale: 1.0,   // ← never zoom out below fit-to-width
          maxScale: 8.0,
          backgroundDecoration:
              const BoxDecoration(color: Color(0xFF1A1A1A)),
          onDocumentLoaded: (doc) {
            if (mounted) {
              setState(() {
                _totalPages = doc.pagesCount;
                _currentPage = 1;
              });
              _scheduleAutoHide();
            }
          },
          onDocumentError: (err) => _tryTextFallback('$err'),
          onPageChanged: (page) {
            if (mounted) setState(() => _currentPage = page);
            _showBars();
          },
          builders: PdfViewPinchBuilders<DefaultBuilderOptions>(
            options: const DefaultBuilderOptions(
                loaderSwitchDuration: Duration(milliseconds: 250)),
            documentLoaderBuilder: (_) => Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(color: Colors.white70),
                  const SizedBox(height: 14),
                  Text(_fileName,
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12),
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  const Text('Loading PDF…',
                      style: TextStyle(
                          color: Colors.white38, fontSize: 11)),
                ],
              ),
            ),
            errorBuilder: (_, err) {
              WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _tryTextFallback('$err'));
              return const Center(
                  child: Icon(Icons.error_outline,
                      size: 48, color: Colors.red));
            },
          ),
        ),

        // Highlight/mark overlay — drawn on top of the PDF
        if (_controller != null && _totalPages > 0)
          Positioned.fill(
            child: _MarkOverlay(
              controller: _controller!,
              marks: _marks,
              currentPage: _currentPage,
              activeTool: _activeTool,
              dragStart: _dragStart,
              dragCurrent: _dragCurrent,
              onDragStart: _onMarkStart,
              onDragUpdate: _onMarkUpdate,
              onDragEnd: _onMarkEnd,
            ),
          ),
      ],
    );
  }

  // ── Top bar ──────────────────────────────────────────────────────────────────
  Widget _buildTopBar(ColorScheme cs) {
    final isBookmarked = _bookmarks.contains(_currentPage);
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
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
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_fileName,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis),
                    if (_totalPages > 0)
                      Text('Page $_currentPage of $_totalPages',
                          style: const TextStyle(
                              color: Colors.white60, fontSize: 11)),
                  ],
                ),
              ),
              // ── Marking tools ──────────────────────────────────────────────
              _toolBtn(Icons.highlight, MarkTool.highlight,
                  Colors.yellow, 'Highlight'),
              _toolBtn(Icons.format_underline, MarkTool.underline,
                  Colors.redAccent, 'Underline'),
              _toolBtn(Icons.auto_fix_high, MarkTool.eraser,
                  Colors.white, 'Eraser'),
              // ── Standard actions ───────────────────────────────────────────
              IconButton(
                icon: Icon(
                    isBookmarked ? Icons.bookmark : Icons.bookmark_border,
                    color: isBookmarked ? Colors.amber : Colors.white),
                tooltip: isBookmarked ? 'Remove bookmark' : 'Bookmark page',
                onPressed: _toggleBookmark,
              ),
              if (_bookmarks.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.list, color: Colors.white),
                  tooltip: 'Bookmarks',
                  onPressed: _showBookmarksList,
                ),
              IconButton(
                icon: const Icon(Icons.find_in_page_outlined,
                    color: Colors.white),
                tooltip: 'Go to page',
                onPressed: _totalPages > 1 ? _showGoToPageDialog : null,
              ),
              IconButton(
                icon: const Icon(Icons.share_outlined, color: Colors.white),
                tooltip: 'Share',
                onPressed: _share,
              ),
              IconButton(
                icon: const Icon(Icons.tune, color: Colors.white),
                tooltip: 'Display settings',
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
            border: active
                ? Border.all(color: color, width: 1.5)
                : null,
          ),
          child: Icon(icon, color: active ? color : Colors.white60, size: 20),
        ),
      ),
    );
  }

  // ── Bottom bar ───────────────────────────────────────────────────────────────
  Widget _buildBottomBar(ColorScheme cs) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(12),
                ),
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
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 7),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 14),
                  trackHeight: 2.5,
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: Colors.white30,
                  thumbColor: Colors.white,
                  overlayColor: Colors.white24,
                ),
                child: Slider(
                  value: _currentPage
                      .toDouble()
                      .clamp(1.0, _totalPages.toDouble()),
                  min: 1,
                  max: _totalPages.toDouble(),
                  divisions: _totalPages > 1 ? _totalPages - 1 : 1,
                  onChanged: (v) =>
                      setState(() => _currentPage = v.round()),
                  onChangeEnd: (v) => _goToPage(v.round()),
                ),
              ),
            ),
            _navBtn(Icons.chevron_right, _currentPage < _totalPages,
                () => _goToPage(_currentPage + 1)),
            // Scroll mode toggle
            IconButton(
              icon: Icon(
                  _horizontalMode ? Icons.swap_vert : Icons.swap_horiz,
                  color: Colors.white70,
                  size: 20),
              tooltip: _horizontalMode ? 'Vertical scroll' : 'Page flip',
              onPressed: _toggleScrollMode,
            ),
            // Clear marks on current page (only shown when marks exist)
            if (_marks.any((m) => m.page == _currentPage))
              IconButton(
                icon: const Icon(Icons.layers_clear,
                    color: Colors.white60, size: 20),
                tooltip: 'Clear marks on this page',
                onPressed: _clearPageMarks,
              ),
          ],
        ),
      ),
    );
  }

  Widget _navBtn(IconData icon, bool enabled, VoidCallback onTap) =>
      IconButton(
        icon: Icon(icon,
            color: enabled ? Colors.white : Colors.white30),
        onPressed: enabled ? onTap : null,
        padding: const EdgeInsets.all(4),
        constraints:
            const BoxConstraints(minWidth: 36, minHeight: 36),
      );

  // ── Page pill ────────────────────────────────────────────────────────────────
  Widget _buildPagePill() {
    final isBookmarked = _bookmarks.contains(_currentPage);
    final hasMarks = _marks.any((m) => m.page == _currentPage);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isBookmarked) ...[
            const Icon(Icons.bookmark, color: Colors.amber, size: 12),
            const SizedBox(width: 4),
          ],
          if (hasMarks) ...[
            const Icon(Icons.highlight, color: Colors.yellow, size: 12),
            const SizedBox(width: 4),
          ],
          Text('$_currentPage / $_totalPages',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  // ── Marking hint ──────────────────────────────────────────────────────────────
  Widget _buildMarkingHint() {
    final (label, color) = switch (_activeTool) {
      MarkTool.highlight => ('Highlight mode — drag to mark', Colors.yellow),
      MarkTool.underline => ('Underline mode — drag to mark', Colors.redAccent),
      MarkTool.eraser => ('Eraser — drag to erase marks', Colors.white70),
      MarkTool.none => ('', Colors.white),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.gesture, color: color, size: 14),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(color: color, fontSize: 11)),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => _selectTool(MarkTool.none),
            child: const Icon(Icons.close, color: Colors.white54, size: 14),
          ),
        ],
      ),
    );
  }

  // ── Settings panel ────────────────────────────────────────────────────────────
  Widget _buildSettingsPanel(ColorScheme cs) {
    return GestureDetector(
      onTap: () {},
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xF0121212),
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(20)),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 16,
                offset: const Offset(0, -4)),
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
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const Text('Display',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            // Night mode
            Row(
              children: [
                const Icon(Icons.nights_stay_outlined,
                    color: Colors.white70, size: 20),
                const SizedBox(width: 10),
                const Expanded(
                    child: Text('Night mode',
                        style: TextStyle(color: Colors.white70))),
                Switch(
                  value: _nightMode,
                  onChanged: (v) => setState(() => _nightMode = v),
                  activeThumbColor: Colors.amber,
                  activeTrackColor:
                      Colors.amber.withValues(alpha: 0.5),
                ),
              ],
            ),
            if (_nightMode) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  const SizedBox(width: 30),
                  const Icon(Icons.brightness_3,
                      color: Colors.white38, size: 16),
                  Expanded(
                    child: Slider(
                      value: _nightOpacity,
                      min: 0.1, max: 0.8, divisions: 14,
                      activeColor: Colors.amber,
                      inactiveColor: Colors.white24,
                      onChanged: (v) =>
                          setState(() => _nightOpacity = v),
                    ),
                  ),
                  const Icon(Icons.brightness_2,
                      color: Colors.white70, size: 16),
                ],
              ),
            ],
            const SizedBox(height: 8),
            // Brightness
            Row(
              children: [
                const Icon(Icons.brightness_medium_outlined,
                    color: Colors.white70, size: 20),
                const SizedBox(width: 10),
                const Text('Brightness',
                    style: TextStyle(color: Colors.white70)),
                Expanded(
                  child: Slider(
                    value: _brightness,
                    min: 0.2, max: 1.0, divisions: 16,
                    activeColor: Colors.white,
                    inactiveColor: Colors.white24,
                    onChanged: (v) =>
                        setState(() => _brightness = v),
                  ),
                ),
                const Icon(Icons.wb_sunny_outlined,
                    color: Colors.white70, size: 16),
              ],
            ),
            const Divider(color: Colors.white12, height: 24),
            // Scroll mode
            Row(
              children: [
                Icon(
                    _horizontalMode
                        ? Icons.swap_horiz
                        : Icons.swap_vert,
                    color: Colors.white70,
                    size: 20),
                const SizedBox(width: 10),
                Expanded(
                    child: Text(
                        _horizontalMode
                            ? 'Page-flip (horizontal)'
                            : 'Continuous scroll (vertical)',
                        style:
                            const TextStyle(color: Colors.white70))),
                TextButton(
                  onPressed: () {
                    setState(() => _settingsOpen = false);
                    _toggleScrollMode();
                  },
                  child: const Text('Switch',
                      style: TextStyle(
                          color: Colors.lightBlueAccent)),
                ),
              ],
            ),
            const Divider(color: Colors.white12, height: 24),
            Row(
              children: [
                const Icon(Icons.info_outline,
                    color: Colors.white38, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$_totalPages pages  •  ${_fileName.length > 28 ? '${_fileName.substring(0, 28)}…' : _fileName}',
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 11),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => setState(() => _settingsOpen = false),
                child: const Text('Close',
                    style: TextStyle(color: Colors.white60)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Dialogs ──────────────────────────────────────────────────────────────────
  void _showGoToPageDialog() {
    _autoHideTimer?.cancel();
    final tec = TextEditingController(text: '$_currentPage');
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Go to page',
            style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: tec,
          style: const TextStyle(color: Colors.white),
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            hintText: '1 – $_totalPages',
            hintStyle: const TextStyle(color: Colors.white38),
            enabledBorder: const OutlineInputBorder(
                borderSide:
                    BorderSide(color: Colors.white24)),
            focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(
                    color: Colors.lightBlueAccent)),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel',
                  style: TextStyle(color: Colors.white54))),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Colors.lightBlueAccent),
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
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Bookmarks',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            if (sorted.isEmpty)
              const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                      child: Text('No bookmarks yet',
                          style:
                              TextStyle(color: Colors.white38))))
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: sorted.length,
                  itemBuilder: (ctx, i) {
                    final p = sorted[i];
                    return ListTile(
                      leading: const Icon(Icons.bookmark,
                          color: Colors.amber, size: 20),
                      title: Text('Page $p',
                          style: const TextStyle(
                              color: Colors.white)),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline,
                            color: Colors.white38, size: 18),
                        onPressed: () {
                          setState(
                              () => _bookmarks.remove(p));
                          _saveBookmarks();
                          Navigator.pop(context);
                        },
                      ),
                      onTap: () {
                        _goToPage(p);
                        Navigator.pop(context);
                      },
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    ).then((_) => _scheduleAutoHide());
  }

  // ── Error / Fallback ──────────────────────────────────────────────────────────
  Widget _buildError(ColorScheme cs) => Scaffold(
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.picture_as_pdf,
                    size: 72, color: Colors.red),
                const SizedBox(height: 20),
                const Text('Cannot open PDF',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                Text(_error!,
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 12),
                    textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      );

  Widget _buildTextFallback(ColorScheme cs) => Scaffold(
        backgroundColor: const Color(0xFF0F0F0F),
        appBar: AppBar(
          backgroundColor: const Color(0xFF1A1A1A),
          foregroundColor: Colors.white,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_fileName,
                  style: const TextStyle(
                      fontSize: 14, color: Colors.white),
                  overflow: TextOverflow.ellipsis),
              const Text('Text view',
                  style: TextStyle(
                      fontSize: 10, color: Colors.white38)),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.share_outlined,
                  color: Colors.white),
              onPressed: _share,
            ),
          ],
        ),
        body: Column(
          children: [
            Container(
              color: Colors.amber.withValues(alpha: 0.12),
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 8),
              child: const Row(
                children: [
                  Icon(Icons.info_outline,
                      size: 15, color: Colors.amber),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Graphical rendering unavailable — showing extracted text.',
                      style: TextStyle(
                          color: Colors.amber, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(18),
                child: SelectableText(
                  _textFallback,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      height: 1.7,
                      letterSpacing: 0.2),
                ),
              ),
            ),
          ],
        ),
      );
}

// ── Mark overlay widget ────────────────────────────────────────────────────────

class _MarkOverlay extends StatelessWidget {
  final PdfControllerPinch controller;
  final List<PdfMark> marks;
  final int currentPage;
  final MarkTool activeTool;
  final Offset? dragStart;
  final Offset? dragCurrent;
  final void Function(DragStartDetails) onDragStart;
  final void Function(DragUpdateDetails) onDragUpdate;
  final void Function(DragEndDetails) onDragEnd;

  const _MarkOverlay({
    required this.controller,
    required this.marks,
    required this.currentPage,
    required this.activeTool,
    required this.dragStart,
    required this.dragCurrent,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Only intercept gestures when a tool is active
      behavior: activeTool != MarkTool.none
          ? HitTestBehavior.opaque
          : HitTestBehavior.translucent,
      onPanStart: activeTool != MarkTool.none ? onDragStart : null,
      onPanUpdate: activeTool != MarkTool.none ? onDragUpdate : null,
      onPanEnd: activeTool != MarkTool.none ? onDragEnd : null,
      child: CustomPaint(
        painter: _MarkPainter(
          controller: controller,
          marks: marks,
          currentPage: currentPage,
          activeTool: activeTool,
          dragStart: dragStart,
          dragCurrent: dragCurrent,
        ),
      ),
    );
  }
}

class _MarkPainter extends CustomPainter {
  final PdfControllerPinch controller;
  final List<PdfMark> marks;
  final int currentPage;
  final MarkTool activeTool;
  final Offset? dragStart;
  final Offset? dragCurrent;

  _MarkPainter({
    required this.controller,
    required this.marks,
    required this.currentPage,
    required this.activeTool,
    required this.dragStart,
    required this.dragCurrent,
  }) : super(repaint: controller);

  @override
  void paint(Canvas canvas, Size size) {
    // Get zoom + viewport offset from controller matrix
    final m = controller.value;
    final zoom = m.row0[0];

    // Paint saved marks for all visible pages
    final visiblePages = controller.visiblePages.keys;
    for (final pageNum in visiblePages) {
      Rect? pageRect;
      try {
        pageRect = controller.getPageRect(pageNum);
      } catch (_) {}
      if (pageRect == null) continue;

      // Transform page rect to screen space
      final tx = m.row0[3]; // translation x (negative = scrolled right)
      final ty = m.row1[3];
      final screenLeft = pageRect.left * zoom + tx;
      final screenTop = pageRect.top * zoom + ty;
      final screenW = pageRect.width * zoom;
      final screenH = pageRect.height * zoom;

      final pageMarks = marks.where((mark) => mark.page == pageNum);
      for (final mark in pageMarks) {
        _paintMark(canvas, mark,
            screenLeft, screenTop, screenW, screenH);
      }
    }

    // Paint the in-progress drag stroke on the current page
    if (dragStart != null &&
        dragCurrent != null &&
        activeTool != MarkTool.none) {
      _paintLiveDrag(canvas, dragStart!, dragCurrent!, activeTool);
    }
  }

  void _paintMark(Canvas canvas, PdfMark mark,
      double sx, double sy, double sw, double sh) {
    final left = sx + mark.start.dx * sw;
    final right = sx + mark.end.dx * sw;
    final y1 = sy + mark.start.dy * sh;
    final y2 = sy + mark.end.dy * sh;

    if (mark.tool == MarkTool.highlight) {
      final paint = Paint()
        ..color = Colors.yellow.withValues(alpha: 0.35)
        ..style = PaintingStyle.fill;
      canvas.drawRect(
          Rect.fromLTRB(
              left.clamp(sx, sx + sw),
              y1.clamp(sy, sy + sh) - 2,
              right.clamp(sx, sx + sw),
              y2.clamp(sy, sy + sh) + 2),
          paint);
    } else if (mark.tool == MarkTool.underline) {
      final paint = Paint()
        ..color = Colors.redAccent.withValues(alpha: 0.9)
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke;
      final baseY = (y1 + y2) / 2 + 14; // below the text line
      canvas.drawLine(
          Offset(left.clamp(sx, sx + sw), baseY.clamp(sy, sy + sh)),
          Offset(right.clamp(sx, sx + sw), baseY.clamp(sy, sy + sh)),
          paint);
    }
  }

  void _paintLiveDrag(
      Canvas canvas, Offset start, Offset end, MarkTool tool) {
    if (tool == MarkTool.highlight) {
      final paint = Paint()
        ..color = Colors.yellow.withValues(alpha: 0.4)
        ..style = PaintingStyle.fill;
      canvas.drawRect(Rect.fromPoints(start, end), paint);
    } else if (tool == MarkTool.underline) {
      final paint = Paint()
        ..color = Colors.redAccent.withValues(alpha: 0.9)
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke;
      final y = (start.dy + end.dy) / 2 + 14;
      canvas.drawLine(Offset(start.dx, y), Offset(end.dx, y), paint);
    } else if (tool == MarkTool.eraser) {
      final paint = Paint()
        ..color = Colors.white.withValues(alpha: 0.15)
        ..style = PaintingStyle.fill;
      canvas.drawRect(Rect.fromPoints(start, end), paint);
    }
  }

  @override
  bool shouldRepaint(_MarkPainter old) =>
      old.marks != marks ||
      old.currentPage != currentPage ||
      old.dragStart != dragStart ||
      old.dragCurrent != dragCurrent ||
      old.activeTool != activeTool;
}

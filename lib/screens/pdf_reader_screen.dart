import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfx/pdfx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/doc_converter.dart';
import '../services/share_service.dart';

/// A full-featured PDF reader modelled after Adobe Acrobat / WPS PDF.
///
/// Features:
/// • Real page rendering via pdfium (PdfViewPinch — pinch-zoom up to 8×)
/// • Auto-hiding top toolbar + bottom bar (tap anywhere to toggle)
/// • Floating page-number pill (always visible while scrolling)
/// • Bottom seek-bar — drag to jump to any page instantly
/// • Scroll mode toggle: vertical continuous  ↔  horizontal page-flip
/// • Night mode (dark overlay, 0–80% opacity)
/// • Brightness slider (0.2–1.0 via ColorFiltered white overlay)
/// • Jump-to-page dialog
/// • Bookmarks — persisted in SharedPreferences per file
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

  // ── UI chrome visibility (auto-hide) ────────────────────────────────────────
  bool _barsVisible = true;
  Timer? _autoHideTimer;

  // ── Display settings ────────────────────────────────────────────────────────
  bool _nightMode = false;
  double _nightOpacity = 0.45;   // 0 – 0.8
  double _brightness = 1.0;       // 0.2 – 1.0  (1.0 = no overlay)
  bool _horizontalMode = false;

  // ── Bookmarks ────────────────────────────────────────────────────────────────
  final Set<int> _bookmarks = {};
  bool _bookmarksLoaded = false;

  // ── Bottom panel (settings drawer) ──────────────────────────────────────────
  bool _settingsOpen = false;

  // ── Animation controller for bars ───────────────────────────────────────────
  late final AnimationController _barAnim;
  late final Animation<double> _barFade;

  String get _fileName => widget.filePath.split('/').last;
  String get _prefsKey => 'pdf_bookmarks_${widget.filePath.hashCode}';

  // ── lifecycle ────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _barAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      value: 1.0,
    );
    _barFade = CurvedAnimation(parent: _barAnim, curve: Curves.easeOut);
    _initPdf();
    _loadBookmarks();
    // Keep screen on while reading
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

  // ── Init PDF ─────────────────────────────────────────────────────────────────
  void _initPdf() {
    final file = File(widget.filePath);
    if (!file.existsSync()) {
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
      if (mounted) setState(() { _textFallback = text; _usedFallback = true; });
    } else {
      _setError('Cannot render this PDF.\n$reason');
    }
  }

  // ── Bookmarks ────────────────────────────────────────────────────────────────
  Future<void> _loadBookmarks() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_prefsKey) ?? [];
    if (mounted) {
      setState(() {
        _bookmarks.addAll(saved.map((s) => int.tryParse(s) ?? 0).where((p) => p > 0));
        _bookmarksLoaded = true;
      });
    }
  }

  Future<void> _saveBookmarks() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, _bookmarks.map((p) => '$p').toList());
  }

  void _toggleBookmark() {
    setState(() {
      if (_bookmarks.contains(_currentPage)) {
        _bookmarks.remove(_currentPage);
      } else {
        _bookmarks.add(_currentPage);
      }
    });
    _saveBookmarks();
    _showQuickToast(_bookmarks.contains(_currentPage)
        ? 'Bookmark added — page $_currentPage'
        : 'Bookmark removed');
  }

  // ── Auto-hide bars ────────────────────────────────────────────────────────────
  void _onTap() {
    if (_settingsOpen) {
      setState(() => _settingsOpen = false);
      return;
    }
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
    _autoHideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && !_settingsOpen) {
        _barAnim.reverse();
        setState(() => _barsVisible = false);
      }
    });
  }

  // ── Navigation ────────────────────────────────────────────────────────────────
  void _goToPage(int page) {
    if (page < 1 || page > _totalPages || _controller == null) return;
    _controller!.animateToPage(
      pageNumber: page,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
    setState(() => _currentPage = page);
  }

  // ── Toast ─────────────────────────────────────────────────────────────────────
  void _showQuickToast(String msg) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.only(bottom: 80, left: 24, right: 24),
    ));
  }

  // ── Share ──────────────────────────────────────────────────────────────────────
  Future<void> _share() async {
    final ok = await ShareService.share([widget.filePath]);
    if (!ok && mounted) _showQuickToast('Could not share this file');
  }

  // ────────────────────────────────────────────────────────────────────────────
  // BUILD
  // ────────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_error != null) return _buildError(cs);
    if (_usedFallback) return _buildTextFallback(cs);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── Main PDF view ──────────────────────────────────────────────────
          _buildPdfView(cs),

          // ── Night mode overlay ─────────────────────────────────────────────
          if (_nightMode)
            IgnorePointer(
              child: Container(
                color: Colors.black.withValues(alpha: _nightOpacity),
              ),
            ),

          // ── Brightness overlay (white, inverted) ───────────────────────────
          if (_brightness < 1.0)
            IgnorePointer(
              child: Container(
                color: Colors.white.withValues(alpha: (1.0 - _brightness) * 0.6),
              ),
            ),

          // ── Tap detector (full screen) ─────────────────────────────────────
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _onTap,
            ),
          ),

          // ── Top toolbar ───────────────────────────────────────────────────
          if (_controller != null)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: FadeTransition(
                opacity: _barFade,
                child: _buildTopBar(cs),
              ),
            ),

          // ── Bottom bar (page slider + controls) ───────────────────────────
          if (_controller != null && _totalPages > 0)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: FadeTransition(
                opacity: _barFade,
                child: _buildBottomBar(cs),
              ),
            ),

          // ── Page number pill (always visible) ─────────────────────────────
          if (_totalPages > 0 && _controller != null)
            Positioned(
              bottom: _barsVisible ? 88 : 16,
              right: 16,
              child: AnimatedOpacity(
                opacity: _barsVisible ? 0.0 : 1.0,
                duration: const Duration(milliseconds: 200),
                child: _buildPagePill(cs),
              ),
            ),

          // ── Settings panel (slides up from bottom) ─────────────────────────
          if (_settingsOpen)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: _buildSettingsPanel(cs),
            ),
        ],
      ),
    );
  }

  // ── PDF View ─────────────────────────────────────────────────────────────────
  Widget _buildPdfView(ColorScheme cs) {
    if (_controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return PdfViewPinch(
      controller: _controller!,
      scrollDirection: _horizontalMode ? Axis.horizontal : Axis.vertical,
      padding: _horizontalMode ? 0 : 6,
      minScale: 0.5,
      maxScale: 8.0,
      backgroundDecoration: const BoxDecoration(color: Color(0xFF1A1A1A)),
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
          loaderSwitchDuration: Duration(milliseconds: 250),
        ),
        documentLoaderBuilder: (_) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Colors.white70),
              const SizedBox(height: 14),
              Text(_fileName,
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              const Text('Loading PDF…',
                  style: TextStyle(color: Colors.white38, fontSize: 11)),
            ],
          ),
        ),
        errorBuilder: (_, err) {
          WidgetsBinding.instance.addPostFrameCallback(
              (_) => _tryTextFallback('$err'));
          return const Center(
            child: Icon(Icons.error_outline, size: 48, color: Colors.red),
          );
        },
      ),
    );
  }

  // ── Top bar ───────────────────────────────────────────────────────────────────
  Widget _buildTopBar(ColorScheme cs) {
    final isBookmarked = _bookmarks.contains(_currentPage);
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xD0000000), Colors.transparent],
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
                    Text(
                      _fileName,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (_totalPages > 0)
                      Text(
                        'Page $_currentPage of $_totalPages',
                        style: const TextStyle(
                            color: Colors.white60, fontSize: 11),
                      ),
                  ],
                ),
              ),
              // Bookmark toggle
              IconButton(
                icon: Icon(
                  isBookmarked ? Icons.bookmark : Icons.bookmark_border,
                  color: isBookmarked ? Colors.amber : Colors.white,
                ),
                tooltip: isBookmarked ? 'Remove bookmark' : 'Bookmark page',
                onPressed: _bookmarksLoaded ? _toggleBookmark : null,
              ),
              // Bookmarks list
              if (_bookmarks.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.list, color: Colors.white),
                  tooltip: 'Bookmarks',
                  onPressed: _showBookmarksList,
                ),
              // Jump to page
              IconButton(
                icon: const Icon(Icons.find_in_page_outlined, color: Colors.white),
                tooltip: 'Go to page',
                onPressed: _totalPages > 1 ? _showGoToPageDialog : null,
              ),
              // Share
              IconButton(
                icon: const Icon(Icons.share_outlined, color: Colors.white),
                tooltip: 'Share',
                onPressed: _share,
              ),
              // Settings (display options)
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

  // ── Bottom bar ─────────────────────────────────────────────────────────────────
  Widget _buildBottomBar(ColorScheme cs) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xD0000000), Colors.transparent],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            // Prev page
            _navBtn(Icons.chevron_left, _currentPage > 1,
                () => _goToPage(_currentPage - 1)),

            // Page number label
            GestureDetector(
              onTap: _showGoToPageDialog,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '$_currentPage / $_totalPages',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ),

            // Seek slider
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
                  value: _currentPage.toDouble().clamp(
                      1.0, _totalPages.toDouble()),
                  min: 1,
                  max: _totalPages.toDouble(),
                  divisions: _totalPages > 1 ? _totalPages - 1 : 1,
                  onChanged: (v) {
                    final p = v.round();
                    setState(() => _currentPage = p);
                  },
                  onChangeEnd: (v) => _goToPage(v.round()),
                ),
              ),
            ),

            // Next page
            _navBtn(Icons.chevron_right, _currentPage < _totalPages,
                () => _goToPage(_currentPage + 1)),

            // Scroll mode toggle
            IconButton(
              icon: Icon(
                _horizontalMode ? Icons.swap_vert : Icons.swap_horiz,
                color: Colors.white70,
                size: 20,
              ),
              tooltip: _horizontalMode ? 'Vertical scroll' : 'Page flip',
              onPressed: _toggleScrollMode,
            ),
          ],
        ),
      ),
    );
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
    _showQuickToast(
        _horizontalMode ? 'Page-flip mode' : 'Continuous scroll mode');
  }

  Widget _navBtn(IconData icon, bool enabled, VoidCallback onTap) {
    return IconButton(
      icon: Icon(icon, color: enabled ? Colors.white : Colors.white30),
      onPressed: enabled ? onTap : null,
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
    );
  }

  // ── Page pill (shown when bars are hidden) ────────────────────────────────────
  Widget _buildPagePill(ColorScheme cs) {
    final isBookmarked = _bookmarks.contains(_currentPage);
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
          Text(
            '$_currentPage / $_totalPages',
            style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  // ── Settings panel ────────────────────────────────────────────────────────────
  Widget _buildSettingsPanel(ColorScheme cs) {
    return GestureDetector(
      onTap: () {}, // absorb taps so they don't toggle bars
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xF0121212),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
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
            // Drag handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Text('Display',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),

            // ── Night mode row ──────────────────────────────────────────────
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
                  activeTrackColor: Colors.amber.withValues(alpha: 0.5),
                ),
              ],
            ),

            // ── Night opacity (only when night mode on) ─────────────────────
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
                      min: 0.1,
                      max: 0.8,
                      divisions: 14,
                      activeColor: Colors.amber,
                      inactiveColor: Colors.white24,
                      onChanged: (v) => setState(() => _nightOpacity = v),
                    ),
                  ),
                  const Icon(Icons.brightness_2,
                      color: Colors.white70, size: 16),
                ],
              ),
            ],

            const SizedBox(height: 8),

            // ── Brightness row ─────────────────────────────────────────────
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
                    min: 0.2,
                    max: 1.0,
                    divisions: 16,
                    activeColor: Colors.white,
                    inactiveColor: Colors.white24,
                    onChanged: (v) => setState(() => _brightness = v),
                  ),
                ),
                const Icon(Icons.wb_sunny_outlined,
                    color: Colors.white70, size: 16),
              ],
            ),

            const Divider(color: Colors.white12, height: 24),

            // ── Scroll mode row ────────────────────────────────────────────
            Row(
              children: [
                Icon(
                  _horizontalMode ? Icons.swap_horiz : Icons.swap_vert,
                  color: Colors.white70,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _horizontalMode
                        ? 'Page-flip mode (horizontal)'
                        : 'Continuous scroll (vertical)',
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    setState(() => _settingsOpen = false);
                    _toggleScrollMode();
                  },
                  child: const Text('Switch',
                      style: TextStyle(color: Colors.lightBlueAccent)),
                ),
              ],
            ),

            const Divider(color: Colors.white12, height: 24),

            // ── Page info ──────────────────────────────────────────────────
            Row(
              children: [
                const Icon(Icons.info_outline,
                    color: Colors.white38, size: 16),
                const SizedBox(width: 8),
                Text(
                  '$_totalPages pages  •  ${_fileName.length > 28 ? '${_fileName.substring(0, 28)}…' : _fileName}',
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ],
            ),

            const SizedBox(height: 8),

            // ── Close settings ─────────────────────────────────────────────
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

  // ── Dialogs ────────────────────────────────────────────────────────────────────
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
                borderSide: BorderSide(color: Colors.white24)),
            focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: Colors.lightBlueAccent)),
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
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
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
                        style: TextStyle(color: Colors.white38))),
              )
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
                          style: const TextStyle(color: Colors.white)),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline,
                            color: Colors.white38, size: 18),
                        onPressed: () {
                          setState(() => _bookmarks.remove(p));
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
  Widget _buildError(ColorScheme cs) {
    return Scaffold(
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
              const Icon(Icons.picture_as_pdf, size: 72, color: Colors.red),
              const SizedBox(height: 20),
              const Text('Cannot open PDF',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              Text(_error!,
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTextFallback(ColorScheme cs) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_fileName,
                style:
                    const TextStyle(fontSize: 14, color: Colors.white),
                overflow: TextOverflow.ellipsis),
            const Text('Text view',
                style: TextStyle(fontSize: 10, color: Colors.white38)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.share_outlined, color: Colors.white),
            onPressed: _share,
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            color: Colors.amber.withValues(alpha: 0.12),
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: const Row(
              children: [
                Icon(Icons.info_outline, size: 15, color: Colors.amber),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Graphical rendering unavailable — showing extracted text.',
                    style: TextStyle(color: Colors.amber, fontSize: 11),
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
}

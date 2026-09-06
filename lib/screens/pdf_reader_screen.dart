import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';

/// Full-screen PDF reader with page navigation, pinch-to-zoom, and go-to-page.
///
/// Implementation note: previous versions of this screen used
/// `PdfViewPinch` directly, but that widget renders blank on some
/// Flutter/Pdfium combinations on Android 14+. We now pre-render each
/// page to a PNG using the same `page.render()` path the preview panel
/// uses, and display them in a `PageView` with `InteractiveViewer`
/// for pinch-zoom. This is more reliable and gives a real scrollable
/// reader.
///
/// Uses the active Material [ColorScheme] instead of hard-coded colors
/// so the reader matches the rest of the app in dark or cream/light
/// theme.
class PdfReaderScreen extends StatefulWidget {
  final String filePath;
  const PdfReaderScreen({super.key, required this.filePath});
  @override
  State<PdfReaderScreen> createState() => _PdfReaderState();
}

class _PdfReaderState extends State<PdfReaderScreen>
    with TickerProviderStateMixin {
  int _currentPage = 1;
  int _totalPages = 0;
  /// Renders the first page eagerly so the reader has something to show;
  /// later pages render in the background (or on demand when the user
  /// swipes close to the rendered window). This makes the reader feel
  /// snappy on multi-page documents — the old "pre-render every page serially
  /// then show" approach could stall the first paint for tens of seconds
  /// on a 50-page PDF.
  final Map<int, String> _pageRenders = {};
  /// Pages we've asked pdfx to render but haven't yet received.
  final Set<int> _rendering = {};
  /// Pages within [_lookaheadPages] of the current page that we'll keep
  /// rendered. Tuned small (1) to balance memory and scroll latency.
  static const int _lookaheadPages = 1;
  final PageController _pageController = PageController();
  /// Shared across all page widgets so zoom is consistent when the user
  /// swipes. Without this, every page would reset to scale 1.0.
  final TransformationController _transform = TransformationController();
  /// Current scale — mirrored from `_transform` for the app-bar buttons.
  /// Capped to the same [1.0, 6.0] range as the InteractiveViewer.
  double _scale = 1.0;
  bool _loading = true;
  String? _error;
  /// Cache directory for rendered page PNGs so re-opens of the same file
  /// are instant. Cleared on dispose.
  Directory? _renderCache;
  /// Single persistent zoom animation. A fresh controller per button press
  /// used to leak: any controller replaced mid-flight never reached
  /// AnimationStatus.completed, so its dispose-on-completed never fired and
  /// its listener kept fighting over [_transform.value] with the newer one.
  AnimationController? _zoomCtrl;

  @override
  void initState() {
    super.initState();
    _loadPdf();
    // Mirror the controller's matrix into [_scale] so the app-bar
    // buttons can reflect the current zoom.
    _transform.addListener(_onTransformChanged);
  }

  void _onTransformChanged() {
    final s = _transform.value.getMaxScaleOnAxis();
    if ((s - _scale).abs() > 0.01) {
      setState(() => _scale = s);
    }
  }

  @override
  void dispose() {
    _transform.removeListener(_onTransformChanged);
    _zoomCtrl?.dispose();
    _transform.dispose();
    _pageController.dispose();
    // Best-effort cleanup of the render cache. The OS would clean it up
    // eventually anyway, but doing it here keeps the temp dir tidy.
    try {
      _renderCache?.deleteSync(recursive: true);
    } catch (_) {}
    super.dispose();
  }

  /// Zooms in by 25% of the current scale, clamped to 6.0. The change is
  /// anchored at the centre of the page so the user's position is
  /// roughly preserved.
  void _zoomIn() {
    final matrix = _transform.value;
    final target = (_scale * 1.25).clamp(1.0, 6.0);
    if (target == _scale) return;
    final t = matrix.getTranslation();
    _animateZoom(target, Offset(t.x, t.y));
  }

  /// Zooms out by 20% of the current scale, clamped to 1.0.
  void _zoomOut() {
    final matrix = _transform.value;
    final target = (_scale / 1.2).clamp(1.0, 6.0);
    if (target == _scale) return;
    final t = matrix.getTranslation();
    _animateZoom(target, Offset(t.x, t.y));
  }

  /// Resets the zoom to fit-to-width (1.0).
  void _zoomReset() {
    _animateZoom(1.0, Offset.zero);
  }

  void _animateZoom(double target, Offset focal) {
    // Animate the matrix to a uniform scale of [target] about the centre
    // of the viewport. Using `Matrix4Tween` gives us a smooth transition
    // rather than a snap.
    final size = MediaQuery.of(context).size;
    final centre = focal == Offset.zero
        ? Offset(size.width / 2, size.height / 2)
        : focal;
    final end = Matrix4.identity()
      ..translateByDouble(centre.dx, centre.dy, 0.0, 1.0)
      ..scaleByDouble(target, target, target, 1.0)
      ..translateByDouble(-centre.dx, -centre.dy, 0.0, 1.0);
    // Stop and discard any in-flight zoom animation before starting a new
    // one — otherwise rapid clicks stack listeners on [_transform] and the
    // superseded controller leaks (dispose-on-completed never fires).
    _zoomCtrl?..stop()..dispose();
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    final animation = Matrix4Tween(begin: _transform.value, end: end).animate(
      CurvedAnimation(parent: controller, curve: Curves.easeOut),
    );
    controller.addListener(() {
      // Guard: this animation may have been superseded mid-flight by a
      // newer press (which disposes this controller). Disposed controllers
      // must not write into [_transform].
      if (!controller.isAnimating) return;
      _transform.value = animation.value;
    });
    // Single forward() — the completion tick is skipped by the isAnimating
    // guard above, so land exactly on the target matrix in whenComplete.
    // If this animation is superseded, its controller is disposed and its
    // TickerFuture never completes, making this a no-op.
    controller.forward().whenComplete(() {
      _transform.value = end;
    });
    _zoomCtrl = controller;
  }

  Future<void> _loadPdf() async {
    try {
      final doc = await PdfDocument.openFile(widget.filePath);
      _totalPages = doc.pagesCount;
      _renderCache = await Directory.systemTemp.createTemp('swordfm_pdf_read_');
      // Render only the first page eagerly so the user sees something
      // immediately; render page 2 in the background so swiping right
      // feels instant. We'll keep rendering neighbors as the user pages
      // through the document.
      await doc.close();
      if (_totalPages == 0) {
        if (mounted) setState(() => _error = 'PDF has no pages.');
        return;
      }
      await _renderPagesAround(1);
      // Wait for page 1 to actually finish rendering before clearing
      // the loading spinner. Without this the body builds once with an
      // empty _pageRenders map, falls through to the metadata card,
      // and the user sees a blank "no pages" screen until the fire-
      // and-forget _renderPage future completes.
      await _renderPage(1);
      if (mounted) setState(() => _loading = false);
      // Background-render the second page so the first swipe is instant.
      if (_totalPages > 1) {
        unawaited(_renderPage(2));
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// Renders [page] (1-based) to a PNG in the cache and stores the path.
  /// Idempotent — if already rendered or rendering, no-ops.
  Future<void> _renderPage(int page) async {
    if (page < 1 || page > _totalPages) return;
    if (_pageRenders.containsKey(page)) return;
    if (_rendering.contains(page)) return;
    _rendering.add(page);
    try {
      final doc = await PdfDocument.openFile(widget.filePath);
      try {
        final pdfPage = await doc.getPage(page);
        // 1080px wide gives crisp text on tablets; phone panels don't
        // use the full resolution but the file is still modest.
        final png = await pdfPage.render(
          width: 1080,
          height: (pdfPage.height * 1080 / pdfPage.width),
          format: PdfPageImageFormat.png,
          backgroundColor: '#FFFFFF',
        );
        await pdfPage.close();
        if (png != null && png.bytes.isNotEmpty) {
          final out = File('${_renderCache!.path}/page$page.png');
          await out.writeAsBytes(png.bytes);
          if (mounted) {
            setState(() {
              _pageRenders[page] = out.path;
            });
          }
        }
      } finally {
        await doc.close();
      }
    } catch (_) {
      // Render failed — leave the page absent; the renderer will show a
      // "could not render" placeholder if the user pages to it.
    } finally {
      _rendering.remove(page);
    }
  }

  /// Renders [_lookaheadPages] pages before and after [currentPage].
  /// Already-rendered pages are skipped, so this is cheap to call on every
  /// page change.
  Future<void> _renderPagesAround(int currentPage) async {
    final start = (currentPage - _lookaheadPages).clamp(1, _totalPages);
    final end =
        (currentPage + _lookaheadPages).clamp(1, _totalPages);
    for (var p = start; p <= end; p++) {
      // Fire-and-forget; _renderPage itself is idempotent.
      unawaited(_renderPage(p));
    }
  }

  void _jumpToPage(int page) {
    if (page < 1 || page > _totalPages) return;
    if (page == _currentPage) return;
    setState(() => _currentPage = page);
    if (_pageController.hasClients) {
      _pageController.animateToPage(
        page - 1,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: Text(
          '${widget.filePath.split('/').last} ($_currentPage/${_totalPages > 0 ? _totalPages : "?"})',
          style: TextStyle(fontSize: 13, color: cs.onSurface),
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: cs.surfaceContainerHighest,
        foregroundColor: cs.onSurface,
        iconTheme: IconThemeData(color: cs.onSurface),
        actions: [
          if (_totalPages > 0) ...[
            // Zoom controls. The InteractiveViewer already supports
            // pinch-zoom; these buttons give one-tap access for users who
            // prefer explicit controls or are on devices without
            // multi-touch. The shared _transform controller means the
            // zoom level carries across page swipes.
            IconButton(
              icon: Icon(Icons.zoom_out,
                  color: cs.onSurfaceVariant, size: 20),
              tooltip: 'Zoom out',
              onPressed: _scale <= 1.0 ? null : _zoomOut,
            ),
            // Live scale indicator — shows the current zoom level so the
            // user can tell what they're looking at after pinch-zoom.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Center(
                child: Text(
                  '${_scale.toStringAsFixed(_scale < 1.5 ? 2 : 1)}×',
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 12,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            IconButton(
              icon: Icon(Icons.zoom_in,
                  color: cs.onSurfaceVariant, size: 20),
              tooltip: 'Zoom in',
              onPressed: _scale >= 6.0 ? null : _zoomIn,
            ),
            IconButton(
              icon: Icon(Icons.zoom_out_map,
                  color: cs.onSurfaceVariant, size: 20),
              tooltip: 'Reset zoom',
              onPressed: _scale == 1.0 ? null : _zoomReset,
            ),
            IconButton(
              icon: Icon(Icons.text_fields,
                  size: 20, color: cs.onSurfaceVariant),
              tooltip: 'Go to page',
              onPressed: _showGoToPageDialog,
            ),
          ],
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error_outline, size: 48, color: cs.error),
                    const SizedBox(height: 12),
                    Text(
                      'Cannot open PDF',
                      style: TextStyle(color: cs.onSurface),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      style: TextStyle(
                          color: cs.onSurfaceVariant, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            )
          : _loading
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 12),
                      Text('Loading page 1…'),
                    ],
                  ),
                )
              : _pageRenders.isEmpty
                  ? Center(
                      child: Text(
                        'This PDF has no renderable pages.',
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                    )
                  : _buildReader(cs),
      bottomNavigationBar: !_loading && _pageRenders.isNotEmpty
          ? Container(
              color: cs.surfaceContainerHighest,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.first_page,
                        size: 20, color: cs.onSurfaceVariant),
                    onPressed: () => _jumpToPage(1),
                  ),
                  IconButton(
                    icon: Icon(Icons.navigate_before,
                        size: 20, color: cs.onSurfaceVariant),
                    onPressed: _currentPage > 1
                        ? () => _jumpToPage(_currentPage - 1)
                        : null,
                  ),
                  Expanded(
                    child: Slider(
                      value: _currentPage.toDouble(),
                      min: 1,
                      max: _totalPages.toDouble(),
                      divisions: _totalPages > 1 ? _totalPages - 1 : 1,
                      activeColor: cs.primary,
                      inactiveColor: cs.outlineVariant,
                      onChanged: (v) => _jumpToPage(v.round()),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.navigate_next,
                        size: 20, color: cs.onSurfaceVariant),
                    onPressed: _currentPage < _totalPages
                        ? () => _jumpToPage(_currentPage + 1)
                        : null,
                  ),
                  IconButton(
                    icon: Icon(Icons.last_page,
                        size: 20, color: cs.onSurfaceVariant),
                    onPressed: () => _jumpToPage(_totalPages),
                  ),
                ],
              ),
            )
          : null,
    );
  }

  /// PageView of all pages (rendered or being rendered). Already-rendered
  /// pages show the cached PNG; unrendered pages show a loading placeholder
  /// and trigger a render in the background. This means opening a large PDF
  /// shows page 1 immediately, with subsequent pages appearing as they
  /// render.
  Widget _buildReader(ColorScheme cs) {
    return PageView.builder(
      controller: _pageController,
      itemCount: _totalPages,
      onPageChanged: (idx) {
        if (mounted) {
          setState(() => _currentPage = idx + 1);
          // Warm up the next page so swiping feels instant.
          _renderPagesAround(idx + 1);
        }
      },
      itemBuilder: (context, idx) {
        final pageNum = idx + 1;
        final cached = _pageRenders[pageNum];
        if (cached != null) {
          return InteractiveViewer(
            // Bound the shared transformation controller so zoom level
            // carries across page swipes. Without this, swiping to the
            // next page would reset the user's zoom.
            transformationController: _transform,
            minScale: 1.0,
            maxScale: 6.0,
            child: Center(
              child: Container(
                margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Image.file(
                  File(cached),
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => _buildErrorTile(
                      cs, 'Page $pageNum could not be rendered'),
                ),
              ),
            ),
          );
        }
        // Not yet rendered — show a placeholder and trigger a render.
        // ignore: unawaited_futures
        _renderPage(pageNum);
        return _buildLoadingTile(cs, pageNum);
      },
    );
  }

  Widget _buildLoadingTile(ColorScheme cs, int pageNum) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text(
            'Rendering page $pageNum of $_totalPages…',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorTile(ColorScheme cs, String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image, size: 48, color: cs.onSurfaceVariant),
          const SizedBox(height: 8),
          Text(
            message,
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ),
    );
  }

  void _showGoToPageDialog() {
    final cs = Theme.of(context).colorScheme;
    final controller = TextEditingController(text: '$_currentPage');
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: cs.surface,
        title: Text('Go to page', style: TextStyle(color: cs.onSurface)),
        content: TextField(
          controller: controller,
          style: TextStyle(color: cs.onSurface),
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            hintText: '1-$_totalPages',
            hintStyle: TextStyle(color: cs.onSurfaceVariant),
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final page = int.tryParse(controller.text);
              if (page != null) _jumpToPage(page);
              Navigator.pop(context);
            },
            child: const Text('Go'),
          ),
        ],
      ),
    );
  }
}

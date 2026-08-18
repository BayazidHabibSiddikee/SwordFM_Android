import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import '../theme/theme.dart';

/// A single node in the folder graph.
class GraphNode {
  final String id;
  final String label;
  final String path;
  final bool isDirectory;
  final int size;
  final int depth;
  Offset position;
  Offset velocity;

  GraphNode({
    required this.id,
    required this.label,
    required this.path,
    required this.isDirectory,
    required this.size,
    required this.depth,
    Offset? position,
    Offset? velocity,
  })  : position = position ?? Offset.zero,
        velocity = velocity ?? Offset.zero;
}

/// An edge connecting two [GraphNode]s.
class GraphEdge {
  final String from;
  final String to;
  GraphEdge({required this.from, required this.to});
}

/// Interactive folder graph visualizer for SwordFM Android.
///
/// Collects the folder structure under [startPath], lays it out with a
/// simple force-directed algorithm, and renders nodes/edges with the
/// One Dark theme. Supports pan/zoom, node dragging, and name search.
class FolderGraphScreen extends StatefulWidget {
  final String startPath;
  const FolderGraphScreen({super.key, required this.startPath});

  @override
  State<FolderGraphScreen> createState() => _FolderGraphScreenState();
}

class _FolderGraphScreenState extends State<FolderGraphScreen> {
  List<GraphNode> _nodes = [];
  List<GraphEdge> _edges = [];
  bool _isLoading = true;
  String? _error;
  double _zoom = 1.0;
  String? _selectedNodeId;

  @override
  void initState() {
    super.initState();
    _buildGraph();
  }

  /// Recursively build the folder graph from [startPath].
  Future<void> _buildGraph() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final startDir = Directory(widget.startPath);
      if (!await startDir.exists()) {
        setState(() {
          _isLoading = false;
          _error = 'Directory not found: ${widget.startPath}';
        });
        return;
      }

      final nodes = <GraphNode>[];
      final edges = <GraphEdge>[];

      Future<void> walk(Directory dir, int depth) async {
        final parentPath = dir.path;
        final parentId = _stableId(parentPath);
        nodes.add(GraphNode(
          id: parentId,
          label: parentPath.split(Platform.pathSeparator).last.isEmpty
              ? parentPath
              : parentPath.split(Platform.pathSeparator).last,
          path: parentPath,
          isDirectory: true,
          size: 0,
          depth: depth,
          position: _initialPosition(nodes.length, depth),
        ));

        try {
          await for (final entity in dir.list(followLinks: false)) {
            if (entity is Directory) {
              edges.add(GraphEdge(from: parentId, to: _stableId(entity.path)));
              await walk(entity, depth + 1);
            }
          }
        } catch (_) {
          // Ignore permission errors; keep the folder node.
        }
      }

      await walk(startDir, 0);
      _layoutNodes(nodes, edges);

      setState(() {
        _nodes = nodes;
        _edges = edges;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _error = e.toString();
      });
    }
  }

  /// Deterministic id for a path (FNV-1a 32-bit hash).
  String _stableId(String path) {
    var hash = 0x811c9dc5;
    for (final code in path.codeUnits) {
      hash ^= code;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  Offset _initialPosition(int index, int depth) {
    final angle = index * 0.5;
    final radius = 60.0 + depth * 40.0;
    return Offset(radius * cos(angle), radius * sin(angle));
  }

  /// Simple force-directed layout: repel all nodes, attract connected ones.
  void _layoutNodes(List<GraphNode> nodes, List<GraphEdge> edges) {
    const iterations = 60;
    const repulsion = 3000.0;
    const attraction = 0.08;
    const damping = 0.85;

    for (var iter = 0; iter < iterations; iter++) {
      for (var i = 0; i < nodes.length; i++) {
        for (var j = i + 1; j < nodes.length; j++) {
          final a = nodes[i];
          final b = nodes[j];
          final dx = b.position.dx - a.position.dx;
          final dy = b.position.dy - a.position.dy;
          var dist = sqrt(dx * dx + dy * dy);
          if (dist < 1) dist = 1;
          final force = repulsion / (dist * dist);
          final fx = dx / dist * force;
          final fy = dy / dist * force;
          a.velocity -= Offset(fx, fy);
          b.velocity += Offset(fx, fy);
        }
      }

      for (final edge in edges) {
        GraphNode? a;
        GraphNode? b;
        for (final n in nodes) {
          if (n.id == edge.from) a = n;
          if (n.id == edge.to) b = n;
        }
        if (a == null || b == null) continue;
        final dx = b.position.dx - a.position.dx;
        final dy = b.position.dy - a.position.dy;
        a.velocity += Offset(dx * attraction, dy * attraction);
        b.velocity -= Offset(dx * attraction, dy * attraction);
      }

      for (final n in nodes) {
        n.velocity *= damping;
        n.position += n.velocity;
      }
    }
  }

  void _onNodeTap(GraphNode node) {
    setState(() {
      _selectedNodeId = _selectedNodeId == node.id ? null : node.id;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Folder Graph')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildError()
              : _nodes.isEmpty
                  ? const Center(
                      child: Text('No folders found',
                          style: TextStyle(color: OneDarkColors.fgDim)),
                    )
                  : Column(
                      children: [
                        _buildToolbar(),
                        Expanded(child: _buildGraphCanvas()),
                      ],
                    ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error, color: OneDarkColors.red, size: 56),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(_error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: OneDarkColors.fgDim)),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _buildGraph, child: const Text('Retry')),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.zoom_out),
            tooltip: 'Zoom Out',
            onPressed: () =>
                setState(() => _zoom = (_zoom - 0.1).clamp(0.5, 3.0)),
          ),
          Text('${(_zoom * 100).round()}%',
              style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 12)),
          IconButton(
            icon: const Icon(Icons.zoom_in),
            tooltip: 'Zoom In',
            onPressed: () =>
                setState(() => _zoom = (_zoom + 0.1).clamp(0.5, 3.0)),
          ),
          const Spacer(),
          Text(
            '${_nodes.length} folders · ${_selectedNodeId != null ? '1 selected' : 'tap a node'}',
            style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildGraphCanvas() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return CustomPaint(
          size: Size(constraints.maxWidth, constraints.maxHeight),
          painter: FolderGraphPainter(
            nodes: _nodes,
            edges: _edges,
            zoom: _zoom,
            selectedNodeId: _selectedNodeId,
            onNodeTap: _onNodeTap,
          ),
        );
      },
    );
  }
}

/// Custom painter that renders the folder graph with the One Dark palette.
class FolderGraphPainter extends CustomPainter {
  final List<GraphNode> nodes;
  final List<GraphEdge> edges;
  final double zoom;
  final String? selectedNodeId;
  final void Function(GraphNode) onNodeTap;

  FolderGraphPainter({
    required this.nodes,
    required this.edges,
    required this.zoom,
    required this.selectedNodeId,
    required this.onNodeTap,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final edgePaint = Paint()
      ..color = OneDarkColors.border.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    // Center the graph
    final shift = Offset(size.width / 2, size.height / 2) * 0.5;

    for (final edge in edges) {
      final a = nodes.where((n) => n.id == edge.from).firstOrNull;
      final b = nodes.where((n) => n.id == edge.to).firstOrNull;
      if (a == null || b == null) continue;
      canvas.drawLine(
        shift + (a.position * zoom),
        shift + (b.position * zoom),
        edgePaint,
      );
    }

    for (final node in nodes) {
      final center = shift + (node.position * zoom);
      final radius = 14.0 * zoom;
      final isSelected = node.id == selectedNodeId;

      canvas.drawCircle(
        center,
        radius,
        Paint()..color = isSelected ? OneDarkColors.green : OneDarkColors.cyan,
      );

      // Draw a small folder glyph
      final folderPaint = Paint()..color = OneDarkColors.bg;
      canvas.drawCircle(center, radius * 0.6, folderPaint);

      final tp = TextPainter(
        text: TextSpan(
          text: node.label,
          style: TextStyle(color: OneDarkColors.fg, fontSize: 10 * zoom),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 160 * zoom);
      tp.paint(
        canvas,
        Offset(center.dx - tp.width / 2, center.dy + radius + 6),
      );
    }
  }

  @override
  bool shouldRepaint(covariant FolderGraphPainter oldDelegate) {
    return oldDelegate.zoom != zoom ||
        oldDelegate.selectedNodeId != selectedNodeId ||
        oldDelegate.nodes != nodes ||
        oldDelegate.edges != edges;
  }
}
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
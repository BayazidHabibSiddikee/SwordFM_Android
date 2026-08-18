import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/screens/folder_graph_screen.dart';

void main() {
  group('GraphNode', () {
    test('creates node with default position at origin', () {
      final node = GraphNode(
        id: 'abc123',
        label: 'test',
        path: '/tmp/test',
        isDirectory: true,
        size: 0,
        depth: 1,
      );
      expect(node.id, 'abc123');
      expect(node.label, 'test');
      expect(node.position, Offset.zero);
      expect(node.velocity, Offset.zero);
      expect(node.isDirectory, isTrue);
      expect(node.depth, 1);
    });

    test('creates node with provided position', () {
      final node = GraphNode(
        id: 'x',
        label: 'y',
        path: '/z',
        isDirectory: false,
        size: 100,
        depth: 2,
        position: const Offset(10, 20),
        velocity: const Offset(1, 2),
      );
      expect(node.position, const Offset(10, 20));
      expect(node.velocity, const Offset(1, 2));
      expect(node.size, 100);
    });
  });

  group('GraphEdge', () {
    test('creates edge with from/to', () {
      final edge = GraphEdge(from: 'a', to: 'b');
      expect(edge.from, 'a');
      expect(edge.to, 'b');
    });
  });

  group('FolderGraphScreen', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('swordfm_graph');
      Directory('${tempDir.path}/sub1').createSync();
      Directory('${tempDir.path}/sub2').createSync();
      File('${tempDir.path}/file.txt').writeAsStringSync('content');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    testWidgets('shows loading indicator while building graph',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(home: FolderGraphScreen(startPath: tempDir.path)),
      );
      // Loading state shows a spinner.
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Folder Graph'), findsOneWidget);
    });

    testWidgets('shows error for missing directory', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: FolderGraphScreen(startPath: '/nonexistent/path/xyz'),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();

      expect(find.textContaining('Directory not found'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    test('FolderGraphPainter shouldRepaint detects zoom change', () {
      final nodes = <GraphNode>[];
      final edges = <GraphEdge>[];
      final painter1 = FolderGraphPainter(
        nodes: nodes,
        edges: edges,
        zoom: 1.0,
        selectedNodeId: null,
        onNodeTap: (_) {},
      );
      final painter2 = FolderGraphPainter(
        nodes: nodes,
        edges: edges,
        zoom: 1.5,
        selectedNodeId: null,
        onNodeTap: (_) {},
      );
      expect(painter1.shouldRepaint(painter2), isTrue);
    });

    test('FolderGraphPainter shouldRepaint false when nothing changes', () {
      final nodes = <GraphNode>[];
      final edges = <GraphEdge>[];
      final painter1 = FolderGraphPainter(
        nodes: nodes,
        edges: edges,
        zoom: 1.0,
        selectedNodeId: null,
        onNodeTap: (_) {},
      );
      final painter2 = FolderGraphPainter(
        nodes: nodes,
        edges: edges,
        zoom: 1.0,
        selectedNodeId: null,
        onNodeTap: (_) {},
      );
      expect(painter1.shouldRepaint(painter2), isFalse);
    });

    test('FolderGraphPainter shouldRepaint detects selection change', () {
      final nodes = <GraphNode>[];
      final edges = <GraphEdge>[];
      final painter1 = FolderGraphPainter(
        nodes: nodes,
        edges: edges,
        zoom: 1.0,
        selectedNodeId: 'a',
        onNodeTap: (_) {},
      );
      final painter2 = FolderGraphPainter(
        nodes: nodes,
        edges: edges,
        zoom: 1.0,
        selectedNodeId: 'b',
        onNodeTap: (_) {},
      );
      expect(painter1.shouldRepaint(painter2), isTrue);
    });
  });
}
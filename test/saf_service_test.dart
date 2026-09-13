import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:swordfm/services/saf_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.swordfm/saf');
  late Future<dynamic> Function(MethodCall) handler;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // The service gates on Platform.isAndroid; force it open so the host
    // test harness can exercise parsing/sorting against a mocked channel.
    SafService.debugForceAndroid = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => handler(call));
  });

  tearDown(() {
    SafService.debugForceAndroid = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('persistedTrees parses grants and drops empty URIs', () async {
    handler = (_) async => [
      {'uri': 'content://tree/1', 'displayName': 'Docs'},
      {'uri': '', 'displayName': 'Bogus'},
    ];
    final trees = await SafService.persistedTrees();
    expect(trees, hasLength(1));
    expect(trees.first.uri, 'content://tree/1');
    expect(trees.first.displayName, 'Docs');
  });

  test('persistedTrees returns empty when channel missing', () async {
    handler = (_) async => throw PlatformException(code: 'nope');
    expect(await SafService.persistedTrees(), isEmpty);
  });

  test('listChildren sorts dirs first then by name', () async {
    handler = (_) async => [
      {
        'documentId': 'b',
        'name': 'zebra.pdf',
        'mimeType': 'application/pdf',
        'size': 10,
        'lastModified': 0,
        'isDir': false,
      },
      {
        'documentId': 'a',
        'name': 'Alpha',
        'mimeType': 'vnd.android.document/directory',
        'size': 0,
        'lastModified': 0,
        'isDir': true,
      },
      {
        'documentId': 'c',
        'name': 'apple.txt',
        'mimeType': 'text/plain',
        'size': 5,
        'lastModified': 0,
        'isDir': false,
      },
      {'documentId': '', 'name': 'ghost', 'isDir': false},
    ];
    const tree = SafTree(uri: 'content://tree/1', displayName: 'Docs');
    final entries = await SafService.listChildren(tree);
    expect(entries.map((e) => e.name).toList(), [
      'Alpha',
      'apple.txt',
      'zebra.pdf',
    ]);
  });

  test('openDocument returns null for dirs and empty paths', () async {
    handler = (_) async => '/cache/saf/a.pdf';
    const tree = SafTree(uri: 'content://tree/1', displayName: 'Docs');
    final dir = SafEntry(
      documentId: 'd',
      name: 'sub',
      mimeType: 'vnd.android.document/directory',
      size: 0,
      lastModified: DateTime(2020),
      isDir: true,
    );
    expect(await SafService.openDocument(tree, dir), isNull);

    handler = (_) async => '';
    final file = SafEntry(
      documentId: 'f',
      name: 'a.pdf',
      mimeType: 'application/pdf',
      size: 1,
      lastModified: DateTime(2020),
      isDir: false,
    );
    expect(await SafService.openDocument(tree, file), isNull);
  });

  test('openTree remembers the grant for later sessions', () async {
    handler = (_) async => {
      'uri': 'content://tree/9',
      'displayName': 'Music',
    };
    final tree = await SafService.openTree();
    expect(tree, isNotNull);
    // A fresh read of persisted grants prunes nothing while the OS still
    // reports the grant.
    handler = (_) async => [
      {'uri': 'content://tree/9', 'displayName': 'Music'},
    ];
    final trees = await SafService.persistedTrees();
    expect(trees.map((t) => t.uri), ['content://tree/9']);
  });
}

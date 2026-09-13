// Tests for EntitlementService.
//
// These install a hand-written fake `FirebaseFirestorePlatform` so that
// loadEntitlement / upgradeToPremium / downgradeToFree exercise the real
// Firestore code paths (document reads, field decoding, error fallback)
// instead of only asserting constructor defaults.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_firestore_platform_interface/cloud_firestore_platform_interface.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:swordfm/services/entitlement_service.dart';

const _testOptions = FirebaseOptions(
  apiKey: 'test-key',
  appId: 'test-app',
  messagingSenderId: 'test-sender',
  projectId: 'test-project',
);

/// Supplies a default FirebaseApp so that `FirebaseFirestore.instance` can
/// resolve `Firebase.app()` without a real platform channel.
class _FakeFirebasePlatform extends FirebasePlatform
    with MockPlatformInterfaceMixin {
  final Map<String, FirebaseAppPlatform> _apps = {
    defaultFirebaseAppName: FirebaseAppPlatform(
      defaultFirebaseAppName,
      _testOptions,
    ),
  };

  @override
  List<FirebaseAppPlatform> get apps => _apps.values.toList();

  @override
  FirebaseAppPlatform app([String name = defaultFirebaseAppName]) =>
      _apps[name]!;

  @override
  Future<FirebaseAppPlatform> initializeApp({
    String? name,
    FirebaseOptions? options,
  }) async {
    final key = name ?? defaultFirebaseAppName;
    return _apps.putIfAbsent(
      key,
      () => FirebaseAppPlatform(key, options ?? _testOptions),
    );
  }
}

/// Records a single `users/{uid}.set(...)` call.
class _Write {
  final String path;
  final Map<String, dynamic> data;
  final bool merge;
  _Write(this.path, this.data, this.merge);
}

/// A minimal in-memory Firestore used to drive EntitlementService.
class _FakeFirestore extends FirebaseFirestorePlatform
    with MockPlatformInterfaceMixin {
  /// Documents keyed by full path, e.g. `users/uid`.
  final Map<String, Map<String, dynamic>> docs = {};

  /// Every write the service performed.
  final List<_Write> writes = [];

  /// When set, `doc().get()` throws this instead of returning data.
  Object? readError;

  /// When set, `doc().set()` throws this instead of recording.
  Object? writeError;

  /// Number of document reads, for asserting call shape.
  int getCount = 0;

  _FakeFirestore();

  /// Clears all recorded state so each test starts from a clean slate.
  void reset() {
    docs.clear();
    writes.clear();
    readError = null;
    writeError = null;
    getCount = 0;
  }

  /// Re-points the global Firestore platform at this instance.
  ///
  /// Needed because the app-facing `FirebaseFirestore` caches the delegate it
  /// resolved on first use; re-assigning in setUp is otherwise a no-op.
  void install() {
    FirebaseFirestorePlatform.instance = this;
  }

  /// `FirebaseFirestore.instance` builds its delegate via this method, so a
  /// fake must return itself for the configured database.
  @override
  FirebaseFirestorePlatform delegateFor({
    required FirebaseApp app,
    required String databaseId,
  }) =>
      this;

  @override
  CollectionReferencePlatform collection(String collectionPath) =>
      _FakeCollection(this, collectionPath);
}

class _FakeCollection extends CollectionReferencePlatform
    with MockPlatformInterfaceMixin {
  final _FakeFirestore fake;

  /// The collection segment, e.g. `users`.
  final String segment;

  _FakeCollection(this.fake, this.segment) : super(fake, segment);

  @override
  DocumentReferencePlatform doc([String? path]) =>
      _FakeDoc(fake, segment, path ?? '');
}

class _FakeDoc extends DocumentReferencePlatform
    with MockPlatformInterfaceMixin {
  final _FakeFirestore fake;

  /// Full document path, e.g. `users/u1`, built from the segments the service
  /// actually requested rather than from the inherited `path` getter.
  final String fullPath;

  _FakeDoc(this.fake, String collection, String doc)
      : fullPath = doc.isEmpty ? collection : '$collection/$doc',
        super(fake, doc.isEmpty ? collection : '$collection/$doc');

  @override
  Future<DocumentSnapshotPlatform> get([GetOptions? options]) async {
    fake.getCount++;
    if (fake.readError != null) throw fake.readError!;
    final data = fake.docs[fullPath];
    // DocumentSnapshotPlatform.exists is `_data != null`, so a missing
    // document MUST be represented as null (not an empty map) or every
    // lookup reports exists == true.
    return DocumentSnapshotPlatform(
      fake,
      fullPath,
      data,
      InternalSnapshotMetadata(hasPendingWrites: false, isFromCache: false),
    );
  }

  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) async {
    if (fake.writeError != null) throw fake.writeError!;
    fake.writes.add(_Write(fullPath, data, options?.merge ?? false));
    fake.docs[fullPath] = {...?fake.docs[fullPath], ...data};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // FirebaseFirestore caches instances keyed by app+database in a private
  // static map, and caches the resolved platform delegate on first use. That
  // means the platform fake can only be installed ONCE per process — swapping
  // FirebaseFirestorePlatform.instance in setUp has no effect after the first
  // test. So install a single long-lived fake and reset its contents per test.
  final fake = _FakeFirestore();
  FirebasePlatform.instance = _FakeFirebasePlatform();

  late EntitlementService service;

  setUp(() {
    FirebaseFirestorePlatform.instance = fake;
    fake
      ..reset()
      ..install();
    service = EntitlementService();
  });

  group('EntitlementService defaults', () {
    test('starts free, premium=false, and still loading', () {
      expect(service.entitlement, Entitlement.free);
      expect(service.isPremium, isFalse);
      expect(service.source, isNull);
      // The service deliberately reports loading until loadEntitlement runs,
      // so the UI can show a spinner instead of flashing "free" UI.
      expect(service.isLoading, isTrue);
    });
  });

  group('loadEntitlement', () {
    test('reads users/{uid} and upgrades to premium', () async {
      fake.docs['users/u1'] = {
        'entitlement': 'premium',
        'source': 'billing',
      };

      await service.loadEntitlement('u1');

      expect(service.entitlement, Entitlement.premium);
      expect(service.isPremium, isTrue);
      expect(service.source, 'billing');
      expect(service.isLoading, isFalse);
      expect(fake.getCount, 1);
    });

    test('treats an explicit free document as free', () async {
      fake.docs['users/u1'] = {'entitlement': 'free', 'source': 'none'};
      await service.loadEntitlement('u1');
      expect(service.isPremium, isFalse);
      expect(service.source, 'none');
    });

    test('defaults source to the string none when the field is absent',
        () async {
      fake.docs['users/u1'] = {'entitlement': 'premium'};
      await service.loadEntitlement('u1');
      expect(service.source, 'none');
    });

    test('an unrecognised entitlement value falls back to free', () async {
      // Guards against a typo or a future value silently granting premium.
      fake.docs['users/u1'] = {'entitlement': 'PREMIUM', 'source': 'manual'};
      await service.loadEntitlement('u1');
      expect(service.isPremium, isFalse);
    });

    test('a missing document leaves the user free with no source', () async {
      await service.loadEntitlement('ghost');
      expect(service.entitlement, Entitlement.free);
      expect(service.source, isNull);
      expect(service.isLoading, isFalse);
    });

    test('a Firestore error is swallowed and the user is left free',
        () async {
      fake.readError = Exception('network down');
      await service.loadEntitlement('u1');
      expect(service.isPremium, isFalse);
      expect(service.source, isNull);
      // isLoading must be cleared even on the error path, or the UI spins
      // forever.
      expect(service.isLoading, isFalse);
    });

    test('notifies listeners once at start and once at completion', () async {
      var notifications = 0;
      service.addListener(() => notifications++);
      await service.loadEntitlement('u1');
      expect(notifications, 2);
    });
  });

  group('upgradeToPremium', () {
    test('writes premium + source with merge:true and updates state',
        () async {
      await service.upgradeToPremium('u1', source: 'donation');

      expect(fake.writes, hasLength(1));
      final w = fake.writes.single;
      expect(w.path, 'users/u1');
      expect(w.merge, isTrue);
      expect(w.data['entitlement'], 'premium');
      expect(w.data['source'], 'donation');
      // activatedAt must be a server timestamp sentinel, not a client clock.
      expect(w.data['activatedAt'], isA<FieldValue>());

      expect(service.isPremium, isTrue);
      expect(service.source, 'donation');
    });

    test('defaults source to manual', () async {
      await service.upgradeToPremium('u2');
      expect(fake.writes.single.data['source'], 'manual');
    });

    test('propagates a write failure and does not grant premium', () async {
      fake.writeError = Exception('permission denied');
      await expectLater(
        service.upgradeToPremium('u1'),
        throwsA(isA<Exception>()),
      );
      // A failed write must not leave in-memory state claiming premium.
      expect(service.isPremium, isFalse);
    });
  });

  group('downgradeToFree', () {
    test('clears entitlement, source and activatedAt via FieldValue.delete',
        () async {
      await service.upgradeToPremium('u1', source: 'billing');
      expect(service.isPremium, isTrue);

      await service.downgradeToFree('u1');

      expect(service.isPremium, isFalse);
      expect(service.source, isNull);

      final w = fake.writes.last;
      expect(w.path, 'users/u1');
      expect(w.merge, isTrue);
      expect(w.data['entitlement'], 'free');
      expect(w.data['source'], isA<FieldValue>());
      expect(w.data['activatedAt'], isA<FieldValue>());
    });
  });
}


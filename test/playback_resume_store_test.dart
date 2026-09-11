import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:swordfm/services/playback_resume_store.dart';

void main() {
  late SharedPreferences preferences;
  late PlaybackResumeStore store;
  late PlaybackMediaIdentity identity;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    preferences = await SharedPreferences.getInstance();
    store = PlaybackResumeStore(preferences);
    identity = PlaybackMediaIdentity(
      path: '/storage/emulated/0/Music/../Music/song.mp3',
      fileSize: 12345,
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );
  });

  PlaybackResumePoint point({int queueIndex = 2}) {
    return PlaybackResumePoint.fromMilliseconds(
      positionMs: 30_000,
      durationMs: 180_000,
      queueIndex: queueIndex,
      updatedAtMillis: 1700000001000,
    );
  }

  test('round trips identity, resume point, and queue index', () async {
    await store.write(identity, point());

    final restored = await store.read(identity);

    expect(restored, isNotNull);
    expect(restored!.positionMs, 30_000);
    expect(restored.durationMs, 180_000);
    expect(restored.queueIndex, 2);
    expect(restored.updatedAtMillis, 1700000001000);
    expect(restored.schemaVersion, playbackResumeSchemaVersion);
    expect(identity.canonicalPath, '/storage/emulated/0/Music/song.mp3');
  });

  test('corrupt JSON is ignored and removed', () async {
    await preferences.setString(
      '${PlaybackResumeStore.storagePrefix}v1.corrupt',
      '{not-json',
    );
    final corruptKey = preferences.getKeys().single;
    final otherIdentity = PlaybackMediaIdentity(
      path: '/tmp/other.mp3',
      fileSize: 1,
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(1),
    );
    // Read uses the identity-derived key, so seed the exact key by writing a
    // valid record first, then replace its value with corrupt JSON.
    await store.write(otherIdentity, point());
    final exactKey = preferences.getKeys().firstWhere(
      (key) => key != corruptKey,
    );
    await preferences.setString(exactKey, '{not-json');

    expect(await store.read(otherIdentity), isNull);
    expect(preferences.containsKey(exactKey), isFalse);
    expect(preferences.containsKey(corruptKey), isTrue);
  });

  test('unsupported schema is ignored and removed', () async {
    await store.write(identity, point());
    final key = preferences.getKeys().single;
    final decoded =
        jsonDecode(preferences.getString(key)!) as Map<String, dynamic>;
    decoded['schemaVersion'] = playbackResumeSchemaVersion + 1;
    await preferences.setString(key, jsonEncode(decoded));

    expect(await store.read(identity), isNull);
    expect(preferences.containsKey(key), isFalse);
  });

  test('identity changes do not restore an old record', () async {
    await store.write(identity, point());
    final changed = PlaybackMediaIdentity.fromMilliseconds(
      path: identity.canonicalPath,
      fileSize: identity.fileSize + 1,
      modifiedAtMillis: identity.modifiedAtMillis,
    );

    expect(await store.read(changed), isNull);
    expect(await store.read(identity), isNotNull);
  });

  test('clear removes one point and clearAll removes all versions', () async {
    final second = PlaybackMediaIdentity(
      path: '/storage/emulated/0/Music/second.mp3',
      fileSize: 5,
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(1700000000001),
    );
    await store.write(identity, point());
    await store.write(second, point(queueIndex: 0));

    await store.clear(identity);
    expect(await store.read(identity), isNull);
    expect(await store.read(second), isNotNull);

    await preferences.setString('playback_resume.v0.old', '{}');
    await store.clearAll();
    expect(
      preferences.getKeys().where(
        (key) => key.startsWith(PlaybackResumeStore.storagePrefix),
      ),
      isEmpty,
    );
  });
}

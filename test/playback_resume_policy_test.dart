import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/playback_resume_policy.dart';
import 'package:swordfm/services/playback_resume_store.dart';

void main() {
  final identity = PlaybackMediaIdentity(
    path: '/music/song.mp3',
    fileSize: 100,
    modifiedAt: DateTime.fromMillisecondsSinceEpoch(1000),
  );

  PlaybackResumePoint point({
    required int positionMs,
    int? durationMs = 100_000,
  }) {
    return PlaybackResumePoint.fromMilliseconds(
      positionMs: positionMs,
      durationMs: durationMs,
      updatedAtMillis: 2000,
    );
  }

  const policy = PlaybackResumePolicy();

  test('rejects near-start positions', () {
    expect(policy.shouldResume(identity, point(positionMs: 4999)), isFalse);
    expect(policy.shouldResume(identity, point(positionMs: 5001)), isTrue);
  });

  test('rejects near-end and 95 percent positions', () {
    expect(policy.shouldResume(identity, point(positionMs: 95_000)), isFalse);
    expect(policy.shouldResume(identity, point(positionMs: 94_999)), isTrue);
    expect(policy.shouldResume(identity, point(positionMs: 95_001)), isFalse);
    expect(policy.shouldResume(identity, point(positionMs: 90_000)), isTrue);
  });

  test('unknown duration applies only the safe near-start rule', () {
    expect(
      policy.shouldResume(identity, point(positionMs: 6_000, durationMs: null)),
      isTrue,
    );
    expect(
      policy.shouldResume(
        identity,
        point(positionMs: 600_000, durationMs: null),
      ),
      isTrue,
    );
  });

  test('identity mismatch never restores', () {
    final other = PlaybackMediaIdentity(
      path: '/music/other.mp3',
      fileSize: 100,
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(1000),
    );
    expect(
      policy.shouldResume(
        identity,
        point(positionMs: 10_000),
        currentIdentity: other,
      ),
      isFalse,
    );
    expect(
      meaningfulPlaybackResume(
        other,
        point(positionMs: 10_000),
        currentIdentity: identity,
      ),
      isNull,
    );
  });

  test('convenience API returns only meaningful points', () {
    expect(
      policy.isMeaningful(
        point(positionMs: 10_000),
        expectedIdentity: identity,
      ),
      isTrue,
    );
    expect(policy.isMeaningful(null), isFalse);
  });
}

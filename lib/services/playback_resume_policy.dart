import 'playback_resume_store.dart';

/// Defaults for deciding whether a saved point is useful to a listener.
class PlaybackResumePolicy {
  const PlaybackResumePolicy({
    this.minimumPosition = const Duration(seconds: 5),
    this.minimumRemaining = const Duration(seconds: 5),
    this.maximumCompletionRatio = 0.95,
  });

  final Duration minimumPosition;
  final Duration minimumRemaining;
  final double maximumCompletionRatio;

  /// Returns whether [point] is meaningful enough to offer for [identity].
  ///
  /// A duration is optional because some players do not know it until after
  /// loading. With no duration, only the near-start threshold is applied.
  /// When a duration is known, positions at or beyond 95% or within the final
  /// five seconds are treated as completed and are not restored.
  bool shouldResume(
    PlaybackMediaIdentity identity,
    PlaybackResumePoint? point, {
    PlaybackMediaIdentity? currentIdentity,
  }) {
    if (point == null) return false;
    if (currentIdentity != null && identity != currentIdentity) return false;
    if (point.position < minimumPosition) return false;

    final duration = point.duration;
    if (duration == null || duration <= Duration.zero) return true;
    if (point.position >= duration) return false;
    if (point.position >= duration * maximumCompletionRatio) return false;
    if (duration - point.position <= minimumRemaining) return false;
    return true;
  }

  /// Convenience form for integrating a point already read for a media item.
  bool isMeaningful(
    PlaybackResumePoint? point, {
    PlaybackMediaIdentity? expectedIdentity,
    PlaybackMediaIdentity? actualIdentity,
  }) {
    if (expectedIdentity == null) {
      return point != null && _isMeaningfulPoint(point);
    }
    return shouldResume(
      expectedIdentity,
      point,
      currentIdentity: actualIdentity ?? expectedIdentity,
    );
  }

  bool _isMeaningfulPoint(PlaybackResumePoint point) {
    if (point.position < minimumPosition) return false;
    final duration = point.duration;
    if (duration == null || duration <= Duration.zero) return true;
    return point.position < duration &&
        point.position < duration * maximumCompletionRatio &&
        duration - point.position > minimumRemaining;
  }
}

/// Applies [PlaybackResumePolicy] to a point returned by a store.
PlaybackResumePoint? meaningfulPlaybackResume(
  PlaybackMediaIdentity identity,
  PlaybackResumePoint? point, {
  PlaybackMediaIdentity? currentIdentity,
  PlaybackResumePolicy policy = const PlaybackResumePolicy(),
}) {
  return policy.shouldResume(identity, point, currentIdentity: currentIdentity)
      ? point
      : null;
}

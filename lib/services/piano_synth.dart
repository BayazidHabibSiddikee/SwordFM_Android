/// Piano note synthesizer.
///
/// Synthesizes short mono PCM buffers in Dart (additive sine fundamental +
/// 2nd/3rd harmonics with an ADSR envelope) and plays them through just_audio
/// via a custom [StreamAudioSource]. Each note is a distinct pitch so the
/// side bar reads as a real keyboard instrument rather than a series of
/// identical blips.
///
/// One octave is covered: C4 (MIDI 60) through C5 (MIDI 67), 8 notes total.
/// The API is intentionally minimal — call [play] with the note index and the
/// synth handles player reuse, cleanup, and ignores calls for out-of-range
/// indices.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:just_audio/just_audio.dart';

/// Frequencies for one octave starting at C4, matching standard equal
/// temperament. Index 0 = C4 (261.63 Hz), index 7 = C5 (523.25 Hz).
const List<double> kFrequencies = <double>[
  261.63, // C4
  293.66, // D4
  329.63, // E4
  349.23, // F4
  392.00, // G4
  440.00, // A4
  493.88, // B4
  523.25, // C5
];

// Synthesis parameters.
const int kSampleRate = 44100;
// Total note duration in samples (~250 ms at 44.1kHz). Long enough to carry
// the ADSR envelope without sounding truncated.
const int kSamplesPerNote = kSampleRate ~/ 4;
// Peak amplitude for 16-bit PCM output. Keep it under 32767 to avoid clipping
// when harmonics sum together.
const double kPeakAmp = 15000.0;

/// Custom [StreamAudioSource] that serves pre-generated PCM data.
class _PcmAudioSource extends StreamAudioSource {
  final Uint8List pcm;
  _PcmAudioSource(this.pcm);

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final data = pcm;
    final offset = start ?? 0;
    final contentLength = end != null
        ? (end - offset).clamp(0, data.length - offset)
        : (data.length - offset);
    return StreamAudioResponse(
      rangeRequestsSupported: true,
      sourceLength: data.length,
      contentLength: contentLength,
      offset: offset,
      contentType: 'audio/raw',
      stream: Stream.value(data.sublist(offset, offset + contentLength)),
    );
  }
}

class PianoSynth {
  PianoSynth._();

  static final PianoSynth _instance = PianoSynth._();
  static PianoSynth get instance => _instance;

  AudioPlayer? _player;
  bool _initialized = false;
  /// True once a source has actually been set on the player. AudioPlayer.stop
  /// throws on a fresh player that has never had setAudioSource() called —
  /// the first tap of any session used to throw PlayerException, which the
  /// catch swallowed but left the player in an error state on some just_audio
  /// versions. Track this so we only call stop() after the first source lands.
  bool _sourceReady = false;

  /// Plays the note at [index] (0..7). Subsequent calls interrupt the current
  /// note so rapid taps don't muddy each other.
  Future<void> play(int index) async {
    if (index < 0 || index >= kFrequencies.length) return;

    if (!_initialized) {
      _player = AudioPlayer();
      _initialized = true;
    }

    // Stop any in-flight note before starting the new one. Skip on the very
    // first call: the player has no source yet, and stop() throws on a fresh
    // just_audio player.
    if (_sourceReady) {
      try {
        await _player!.stop();
      } catch (_) {}
    }

    final freq = kFrequencies[index];
    final pcmBytes = _synthesizeNote(freq);
    final player = _player!;
    try {
      await player.setAudioSource(_PcmAudioSource(pcmBytes));
      _sourceReady = true;
      await player.play();
    } catch (e) {
      debugPrint('PianoSynth: playback failed for index $index: $e');
    }
  }

  /// Releases the underlying player. Call once at app teardown if desired.
  void dispose() {
    _player?.dispose();
    _player = null;
    _initialized = false;
    _sourceReady = false;
  }

  /// Generates a short PCM buffer for a single note at [frequency].
  ///
  /// Three overlapping sine waves produce the tone (fundamental + 2nd harmonic
  /// at half amplitude + 3rd at quarter amplitude). An ADSR envelope shapes
  /// the amplitude over time so the note sounds like a plucked string rather
  /// than a continuous beep.
  Uint8List _synthesizeNote(double frequency) {
    // Pre-allocate the whole PCM buffer once. Previous implementation built
    // a new Int16List(1) + Uint8List view inside the per-sample loop — about
    // 11,025 short-lived allocations per note, ~22k per sidebar tap. Rapid
    // tapping allocated tens of thousands of garbage objects in a couple of
    // seconds; this buffer keeps each note down to a single allocation.
    final pcm = Int16List(kSamplesPerNote);
    final samplesPerFrame = (kSampleRate / frequency).round();
    final twoPi = 2.0 * math.pi;

    // ADSR sample counts.
    final attackSamples = (5 * kSampleRate / 1000).round();
    final decaySamples = (50 * kSampleRate / 1000).round();
    final sustainSamples = (150 * kSampleRate / 1000).round();
    final releaseSamples = (50 * kSampleRate / 1000).round();
    final attackEnd = attackSamples;
    final decayEnd = attackEnd + decaySamples;
    final sustainEnd = decayEnd + sustainSamples;
    final releaseStart = kSamplesPerNote - releaseSamples;

    for (var i = 0; i < kSamplesPerNote; i++) {
      // ADSR envelope.
      double env;
      if (i < attackSamples) {
        env = i / attackSamples;
      } else if (i < decayEnd) {
        env = 1.0 - 0.3 * ((i - attackEnd) / decaySamples);
      } else if (i < sustainEnd) {
        env = 0.7;
      } else if (i < releaseStart) {
        env = 0.7;
      } else {
        env = 0.7 * ((kSamplesPerNote - i) / releaseSamples);
      }

      // Sum three sines: fundamental + 2nd + 3rd harmonic.
      double sample = 0.0;
      for (int harm = 1; harm <= 3; harm++) {
        final amp = 1.0 / (harm * harm);
        final phase = twoPi * harm * i / samplesPerFrame;
        sample += amp * math.sin(phase);
      }

      final amplitude = sample * env * kPeakAmp;
      // Clamp to 16-bit signed range.
      final clamped = amplitude.clamp(-32768.0, 32767.0);
      pcm[i] = clamped.toInt();
    }

    return pcm.buffer.asUint8List();
  }
}

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/loudness_meter.dart';

List<double> _sine({
  required double dbfs,
  required int sampleRate,
  required double seconds,
  int channels = 2,
  double hz = 1000,
}) {
  final amp = math.pow(10, dbfs / 20).toDouble();
  final frames = (sampleRate * seconds).round();
  final out = List<double>.filled(frames * channels, 0);
  for (var i = 0; i < frames; i++) {
    final v = amp * math.sin(2 * math.pi * hz * i / sampleRate);
    for (var c = 0; c < channels; c++) {
      out[i * channels + c] = v;
    }
  }
  return out;
}

void main() {
  test('1 kHz stereo sine at -20 dBFS reads -20 LUFS (EBU Tech 3341)', () {
    for (final rate in [44100, 48000, 24000]) {
      final lufs = LoudnessMeter.measureSamples(
        _sine(dbfs: -20, sampleRate: rate, seconds: 5),
        channels: 2,
        sampleRate: rate,
      );
      expect(lufs, closeTo(-20.0, 0.1), reason: '$rate Hz');
    }
  });

  test('quiet passages below the relative gate do not drag the level down', () {
    const rate = 48000;
    final loud = _sine(dbfs: -20, sampleRate: rate, seconds: 10);
    final quiet = _sine(dbfs: -40, sampleRate: rate, seconds: 10);
    final lufs = LoudnessMeter.measureSamples(
      [...loud, ...quiet],
      channels: 2,
      sampleRate: rate,
    );
    expect(lufs, closeTo(-20.0, 0.2));
  });

  test('finds where the music starts and stops, keeping a quiet fade', () {
    const rate = 24000;
    List<double> silence(double seconds) =>
        List<double>.filled((rate * seconds).round() * 2, 0);
    final a = LoudnessMeter.analyzeSamples(
      [
        ...silence(2),
        ..._sine(dbfs: -12, sampleRate: rate, seconds: 5),
        // A fade-out tail far quieter than the song, but still music.
        ..._sine(dbfs: -40, sampleRate: rate, seconds: 1),
        ...silence(3),
      ],
      channels: 2,
      sampleRate: rate,
    )!;
    expect(a.lufs, closeTo(-12, 0.3));
    expect(a.musicStart, closeTo(2.0, 0.11));
    expect(a.musicEnd, closeTo(8.0, 0.21));
    expect(a.length, closeTo(11.0, 0.01));
  });

  test('silence has no loudness', () {
    expect(
      LoudnessMeter.measureSamples(
        List<double>.filled(48000 * 2 * 2, 0),
        channels: 2,
        sampleRate: 48000,
      ),
      isNull,
    );
  });

  test('reads a 16-bit WAV from disk', () async {
    const rate = 44100;
    final samples = _sine(dbfs: -23, sampleRate: rate, seconds: 4);
    final pcm = ByteData(samples.length * 2);
    for (var i = 0; i < samples.length; i++) {
      pcm.setInt16(i * 2, (samples[i] * 32767).round(), Endian.little);
    }
    final header = ByteData(44);
    void tag(int at, String s) {
      for (var i = 0; i < 4; i++) {
        header.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    tag(0, 'RIFF');
    header.setUint32(4, 36 + pcm.lengthInBytes, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, 2, Endian.little);
    header.setUint32(24, rate, Endian.little);
    header.setUint32(28, rate * 4, Endian.little);
    header.setUint16(32, 4, Endian.little);
    header.setUint16(34, 16, Endian.little);
    tag(36, 'data');
    header.setUint32(40, pcm.lengthInBytes, Endian.little);

    final dir = await Directory.systemTemp.createTemp('loudness_test');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/tone.wav');
    await file.writeAsBytes([
      ...header.buffer.asUint8List(),
      ...pcm.buffer.asUint8List(),
    ]);
    expect(await LoudnessMeter.measureWav(file.path), closeTo(-23.0, 0.1));
  });

  test('rejects files that are not WAV', () async {
    final dir = await Directory.systemTemp.createTemp('loudness_test');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/song.m4a')..writeAsBytesSync([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13]);
    expect(await LoudnessMeter.measureWav(file.path), isNull);
  });

  group('onsets', () {
    /// A steady bass line with short "sung" notes (a vowel-like tone with a
    /// quick attack and a decay) starting at [notesMs].
    List<double> song(List<int> notesMs, {double seconds = 6}) {
      const rate = 44100;
      final frames = (rate * seconds).round();
      final out = List<double>.filled(frames, 0);
      for (var i = 0; i < frames; i++) {
        // Bass drone at 55 Hz, louder than the voice: outside the voice
        // range, so it must never register.
        out[i] = 0.4 * math.sin(2 * math.pi * 55 * i / rate);
      }
      for (final start in notesMs) {
        final s0 = start * rate ~/ 1000;
        for (var j = 0; j < rate * 0.25 && s0 + j < frames; j++) {
          final t = j / rate;
          final env = math.min(1.0, t / 0.01) * math.exp(-t * 6);
          out[s0 + j] += 0.2 * env *
              (math.sin(2 * math.pi * 440 * t) + 0.5 * math.sin(2 * math.pi * 880 * t));
        }
      }
      return out;
    }

    test('are found where notes start, within a hop or two', () {
      const notes = [500, 1100, 1450, 2300, 2700, 3600, 4200, 5000];
      final analysis = LoudnessMeter.analyzeSamples(
        song(notes),
        channels: 1,
        sampleRate: 44100,
      )!;
      expect(analysis.onsetsMs, hasLength(notes.length));
      for (var i = 0; i < notes.length; i++) {
        expect((analysis.onsetsMs[i] - notes[i]).abs(), lessThanOrEqualTo(20),
            reason: 'note at ${notes[i]} ms');
      }
    });

    test('drum hits are not taken for sung notes', () {
      const rate = 44100;
      const notes = [600, 1800, 3000];
      const hits = [1200, 2400, 3600, 4200];
      final out = song(notes);
      final noise = math.Random(7);
      for (final start in hits) {
        // A snare: a loud burst of noise that dies away within 100 ms.
        final s0 = start * rate ~/ 1000;
        for (var j = 0; j < rate * 0.15; j++) {
          final env = math.exp(-j / rate * 40);
          out[s0 + j] += 0.6 * env * (noise.nextDouble() * 2 - 1);
        }
      }
      final analysis =
          LoudnessMeter.analyzeSamples(out, channels: 1, sampleRate: rate)!;
      expect(analysis.onsetsMs, hasLength(notes.length),
          reason: 'found ${analysis.onsetsMs}');
      for (var i = 0; i < notes.length; i++) {
        expect((analysis.onsetsMs[i] - notes[i]).abs(), lessThanOrEqualTo(20));
      }
    });

    test('a steady sound has none', () {
      final analysis = LoudnessMeter.analyzeSamples(
        song(const []),
        channels: 1,
        sampleRate: 44100,
      )!;
      expect(analysis.onsetsMs, isEmpty);
    });
  });
}

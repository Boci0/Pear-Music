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
}

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/waveform_service.dart';

void main() {
  group('WaveformService', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('waveform_test_');
      WaveformService.instance.setCacheDirectoryForTesting(tempDir);
      WaveformService.instance.clearMemoryCache();
    });

    tearDown(() async {
      WaveformService.instance.setCacheDirectoryForTesting(null);
      WaveformService.instance.clearMemoryCache();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('downsamples PCM samples into normalized 128-bar amplitude peaks', () {
      final samples = Int16List(1024);
      for (int i = 0; i < samples.length; i++) {
        // Generate alternating sine-like amplitude
        samples[i] = ((i % 64) * 500).clamp(-32768, 32767);
      }

      final peaks = WaveformService.downsamplePeaksForTesting(samples, WaveformService.barCount);
      expect(peaks.length, WaveformService.barCount);
      for (final p in peaks) {
        expect(p, greaterThanOrEqualTo(0.0));
        expect(p, lessThanOrEqualTo(1.0));
      }
    });

    test('memory cache returns cached peaks immediately', () {
      final testPeaks = List<double>.generate(WaveformService.barCount, (i) => i / WaveformService.barCount);
      WaveformService.instance.putInMemoryCacheForTesting('song_mem_1', testPeaks);

      final cached = WaveformService.instance.getCachedSync('song_mem_1');
      expect(cached, isNotNull);
      expect(cached!.length, WaveformService.barCount);
      expect(cached[0], 0.0);

      WaveformService.instance.clearMemoryCache();
      expect(WaveformService.instance.getCachedSync('song_mem_1'), isNull);
    });

    test('disk cache reads binary .wf waveform file without spawning processes', () async {
      const songId = 'song_disk_1';
      final diskFile = File('${tempDir.path}/$songId.wf');

      final rawBytes = Uint8List(WaveformService.barCount);
      for (int i = 0; i < rawBytes.length; i++) {
        rawBytes[i] = (i * 2).clamp(0, 255);
      }
      await diskFile.writeAsBytes(rawBytes);

      // audioFile is null, so it must rely strictly on disk cache
      final peaks = await WaveformService.instance.getWaveform(songId, null);
      expect(peaks, isNotNull);
      expect(peaks!.length, WaveformService.barCount);
      expect(peaks[0], 0.0);
      expect(peaks[127], closeTo(254 / 255.0, 0.01));

      // Should now also be populated in memory cache
      expect(WaveformService.instance.getCachedSync(songId), isNotNull);
    });

    test('in-flight requests are deduplicated into a single future', () async {
      const songId = 'song_inflight_1';
      final diskFile = File('${tempDir.path}/$songId.wf');
      final rawBytes = Uint8List.fromList(List.filled(WaveformService.barCount, 128));
      await diskFile.writeAsBytes(rawBytes);

      final future1 = WaveformService.instance.getWaveform(songId, null);
      final future2 = WaveformService.instance.getWaveform(songId, null);

      expect(identical(future1, future2), isTrue);

      final result1 = await future1;
      final result2 = await future2;
      expect(result1, equals(result2));
    });
  });
}

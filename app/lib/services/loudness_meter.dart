import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Integrated loudness (LUFS) of a PCM WAV file, measured the ITU-R BS.1770
/// way that EBU R128, YouTube and Spotify normalisation are built on:
/// K-weighting, 400 ms blocks every 100 ms, then an absolute gate at -70 LUFS
/// and a relative gate 10 LU under the level of what passed the first gate.
///
/// Pure Dart and streamed from disk in chunks, so a long song never sits in
/// memory. Reads 16-bit integer or 32-bit float PCM, any rate, any channel
/// count (every channel weighted 1.0, which is exact for mono and stereo).
class LoudnessMeter {
  LoudnessMeter._();

  /// Returns null when the file is not a WAV this can read, or when the
  /// audio is silent (no block passes the absolute gate).
  static Future<double?> measureWav(String path) async =>
      (await analyzeWav(path))?.lufs;

  /// Loudness plus where the music starts and ends, in one pass over [path].
  /// Null when the file is not a WAV this can read or is silent throughout.
  static Future<LoudnessAnalysis?> analyzeWav(String path) async {
    final raf = await File(path).open();
    try {
      final format = await _readHeader(raf);
      if (format == null) return null;
      final meter = _Accumulator(format.channels, format.sampleRate);
      final bytesPerSample = format.bits ~/ 8;
      final frameBytes = bytesPerSample * format.channels;
      const chunkFrames = 65536;
      var remaining = format.dataLength;
      while (remaining >= frameBytes) {
        final want = math.min(remaining, chunkFrames * frameBytes);
        final bytes = await raf.read(want - want % frameBytes);
        if (bytes.isEmpty) break;
        remaining -= bytes.length;
        final data = ByteData.sublistView(bytes);
        final samples = bytes.length ~/ bytesPerSample;
        if (format.isFloat) {
          for (var i = 0; i < samples; i++) {
            meter.add(data.getFloat32(i * 4, Endian.little));
          }
        } else {
          for (var i = 0; i < samples; i++) {
            meter.add(data.getInt16(i * 2, Endian.little) / 32768.0);
          }
        }
      }
      return meter.analysis();
    } finally {
      await raf.close();
    }
  }

  /// Integrated loudness of interleaved samples in -1..1. Used by tests.
  static double? measureSamples(
    List<double> interleaved, {
    required int channels,
    required int sampleRate,
  }) {
    final meter = _Accumulator(channels, sampleRate);
    for (final s in interleaved) {
      meter.add(s);
    }
    return meter.integrated();
  }

  /// [analyzeWav] for interleaved samples in -1..1. Used by tests.
  static LoudnessAnalysis? analyzeSamples(
    List<double> interleaved, {
    required int channels,
    required int sampleRate,
  }) {
    final meter = _Accumulator(channels, sampleRate);
    for (final s in interleaved) {
      meter.add(s);
    }
    return meter.analysis();
  }

  static Future<_WavFormat?> _readHeader(RandomAccessFile raf) async {
    final riff = await raf.read(12);
    if (riff.length < 12 ||
        String.fromCharCodes(riff.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(riff.sublist(8, 12)) != 'WAVE') {
      return null;
    }
    int? channels, sampleRate, bits, audioFormat;
    final fileLength = await raf.length();
    while (true) {
      final head = await raf.read(8);
      if (head.length < 8) return null;
      final id = String.fromCharCodes(head.sublist(0, 4));
      final size = ByteData.sublistView(head).getUint32(4, Endian.little);
      if (id == 'fmt ') {
        final fmt = ByteData.sublistView(await raf.read(size));
        audioFormat = fmt.getUint16(0, Endian.little);
        channels = fmt.getUint16(2, Endian.little);
        sampleRate = fmt.getUint32(4, Endian.little);
        bits = fmt.getUint16(14, Endian.little);
        // WAVE_FORMAT_EXTENSIBLE keeps the real format in its sub-format GUID.
        if (audioFormat == 0xFFFE && size >= 26) {
          audioFormat = fmt.getUint16(24, Endian.little);
        }
        if (size.isOdd) await raf.read(1);
      } else if (id == 'data') {
        if (channels == null || sampleRate == null || bits == null) {
          return null;
        }
        final isFloat = audioFormat == 3 && bits == 32;
        if (!isFloat && !(audioFormat == 1 && bits == 16)) return null;
        if (channels < 1 || sampleRate < 8000) return null;
        // A writer that could not seek back leaves the size unset (0 or
        // 0xFFFFFFFF); the data then runs to the end of the file.
        final position = await raf.position();
        final available = fileLength - position;
        final length = size == 0 || size > available ? available : size;
        return _WavFormat(channels, sampleRate, bits, isFloat, length);
      } else {
        await raf.setPosition(await raf.position() + size + (size & 1));
      }
    }
  }
}

/// What one pass over a song finds: its integrated loudness and the span
/// that holds music, so silent intros and outros can be skipped.
class LoudnessAnalysis {
  final double lufs;

  /// Seconds of silence before the music starts.
  final double musicStart;

  /// Seconds from the start of the file to where the music stops.
  final double musicEnd;

  /// Length of the audio that was analysed, in seconds.
  final double length;

  /// Milliseconds at which the level in the voice range jumps up: where
  /// notes and sung syllables usually start. Used to line estimated lyric
  /// word timing up with the song. Sorted, possibly empty.
  final List<int> onsetsMs;

  const LoudnessAnalysis({
    required this.lufs,
    required this.musicStart,
    required this.musicEnd,
    required this.length,
    this.onsetsMs = const [],
  });

  LoudnessAnalysis withOnsets(List<int> onsets) => LoudnessAnalysis(
        lufs: lufs,
        musicStart: musicStart,
        musicEnd: musicEnd,
        length: length,
        onsetsMs: onsets,
      );
}

/// Finds onsets in the voice range (about 200 Hz to 3 kHz, which leaves out
/// most of the kick drum, bass and cymbals): 10 ms energy hops, then the
/// moments the level rises clearly above the hops just before it.
///
/// Only onsets followed by a pitched sound are kept. A snare hit or a clap
/// is noise and fades fast; a sung syllable holds a note. Without this check
/// the drums, which hit harder than the voice, won most of the snaps.
class _OnsetDetector {
  final int _hopFrames;
  final _Biquad _highPass;
  final _Biquad _lowPass;
  final List<double> _hopDb = [];
  double _hopSum = 0;
  int _frameInHop = 0;

  /// The filtered signal kept at a lower rate (the filter already removed
  /// everything above 3 kHz) for the pitch check, as 16-bit samples.
  final int _decimate;
  late final double _keptRate;
  final List<Int16List> _kept = [];
  Int16List _chunk = Int16List(_chunkSize);
  int _inChunk = 0;
  int _decimateCount = 0;
  static const int _chunkSize = 1 << 16;

  _OnsetDetector(int sampleRate)
    : _hopFrames = math.max(1, (sampleRate / 100).round()),
      _highPass = _Biquad.highPass(200, sampleRate),
      _lowPass = _Biquad.lowPass(3000, sampleRate),
      _decimate = math.max(1, sampleRate ~/ 8000) {
    _keptRate = sampleRate / _decimate;
  }

  void addFrame(double mono) {
    final y = _lowPass.process(_highPass.process(mono));
    if (++_decimateCount == _decimate) {
      _decimateCount = 0;
      _chunk[_inChunk] = (y * 32767).round().clamp(-32768, 32767);
      if (++_inChunk == _chunkSize) {
        _kept.add(_chunk);
        _chunk = Int16List(_chunkSize);
        _inChunk = 0;
      }
    }
    _hopSum += y * y;
    if (++_frameInHop == _hopFrames) {
      _hopDb.add(10 * math.log(_hopSum / _hopFrames + 1e-12) / math.ln10);
      _hopSum = 0;
      _frameInHop = 0;
    }
  }

  /// Onset times in milliseconds.
  List<int> onsets() {
    final n = _hopDb.length;
    if (n < 10) return const [];
    // Quiet hops (well under the song's loud parts) never count: breaths,
    // reverb tails and hiss rise and fall too.
    final sorted = List<double>.of(_hopDb)..sort();
    final floor = sorted[(n * 0.9).floor()] - 35;

    // Rise over the recent past: this hop against the mean of the three
    // before it, in dB, so a loud and a quiet passage are judged alike.
    final rise = List<double>.filled(n, 0);
    for (var t = 3; t < n; t++) {
      if (_hopDb[t] < floor) continue;
      final before = (_hopDb[t - 1] + _hopDb[t - 2] + _hopDb[t - 3]) / 3;
      final d = _hopDb[t] - before;
      if (d > 0) rise[t] = d;
    }

    // Peaks of the rise: the highest within 50 ms either side, at least 3 dB,
    // and clearly above the rise nearby (dense instruments keep that high).
    const halfPeak = 5;
    const halfLocal = 50;
    const minGapHops = 8; // 80 ms
    final result = <int>[];
    var localSum = 0.0;
    var lo = 0, hi = -1;
    var last = -minGapHops;
    for (var t = 0; t < n; t++) {
      while (hi < math.min(n - 1, t + halfLocal)) {
        localSum += rise[++hi];
      }
      while (lo < t - halfLocal) {
        localSum -= rise[lo++];
      }
      final r = rise[t];
      if (r < 3.0) continue;
      final localMean = localSum / (hi - lo + 1);
      if (r < localMean + 1.5) continue;
      var isPeak = true;
      for (var k = math.max(0, t - halfPeak); k <= math.min(n - 1, t + halfPeak); k++) {
        if (rise[k] > r || (rise[k] == r && k < t)) {
          isPeak = false;
          break;
        }
      }
      if (!isPeak || t - last < minGapHops) continue;
      if (!_pitchedAfter(t * 10)) continue;
      last = t;
      result.add(t * 10);
    }
    return result;
  }

  int get _keptLength => _kept.length * _chunkSize + _inChunk;

  double _keptAt(int i) {
    final c = i ~/ _chunkSize;
    final v = c < _kept.length ? _kept[c][i % _chunkSize] : _chunk[i % _chunkSize];
    return v / 32768;
  }

  /// Whether a pitched sound (80 Hz to 1 kHz, a voice's range) holds in the
  /// 40 ms starting 20 ms after [ms], past the attack where any hit is
  /// noisy: some lag must repeat the waveform closely (normalised
  /// autocorrelation of at least 0.6).
  bool _pitchedAfter(int ms) {
    final start = ((ms + 20) * _keptRate / 1000).round();
    final length = (0.040 * _keptRate).round();
    final minLag = math.max(1, (_keptRate / 1000).floor());
    final maxLag = (_keptRate / 80).ceil();
    if (start < 0 || start + length + maxLag > _keptLength) return false;
    final x = Float64List(length + maxLag);
    for (var i = 0; i < x.length; i++) {
      x[i] = _keptAt(start + i);
    }
    var e0 = 0.0;
    for (var i = 0; i < length; i++) {
      e0 += x[i] * x[i];
    }
    if (e0 <= 1e-9) return false;
    // Energy of the shifted window, kept up to date as the lag grows.
    var eLag = 0.0;
    for (var i = minLag; i < minLag + length; i++) {
      eLag += x[i] * x[i];
    }
    for (var lag = minLag; lag <= maxLag; lag++) {
      var dot = 0.0;
      for (var i = 0; i < length; i++) {
        dot += x[i] * x[i + lag];
      }
      if (eLag > 1e-9 && dot / math.sqrt(e0 * eLag) >= 0.6) return true;
      if (lag < maxLag) {
        eLag += x[lag + length] * x[lag + length] - x[lag] * x[lag];
      }
    }
    return false;
  }
}

/// A second-order filter (RBJ cookbook), direct form II transposed.
class _Biquad {
  final double b0, b1, b2, a1, a2;
  double _z1 = 0, _z2 = 0;

  _Biquad(this.b0, this.b1, this.b2, this.a1, this.a2);

  factory _Biquad.highPass(double f0, int sampleRate) {
    final w = 2 * math.pi * f0 / sampleRate;
    final alpha = math.sin(w) / (2 * math.sqrt1_2);
    final cosW = math.cos(w);
    final a0 = 1 + alpha;
    return _Biquad((1 + cosW) / 2 / a0, -(1 + cosW) / a0, (1 + cosW) / 2 / a0,
        -2 * cosW / a0, (1 - alpha) / a0);
  }

  factory _Biquad.lowPass(double f0, int sampleRate) {
    final w = 2 * math.pi * math.min(f0, sampleRate * 0.45) / sampleRate;
    final alpha = math.sin(w) / (2 * math.sqrt1_2);
    final cosW = math.cos(w);
    final a0 = 1 + alpha;
    return _Biquad((1 - cosW) / 2 / a0, (1 - cosW) / a0, (1 - cosW) / 2 / a0,
        -2 * cosW / a0, (1 - alpha) / a0);
  }

  double process(double x) {
    final y = b0 * x + _z1;
    _z1 = b1 * x - a1 * y + _z2;
    _z2 = b2 * x - a2 * y;
    return y;
  }
}

class _WavFormat {
  final int channels;
  final int sampleRate;
  final int bits;
  final bool isFloat;
  final int dataLength;
  const _WavFormat(
    this.channels,
    this.sampleRate,
    this.bits,
    this.isFloat,
    this.dataLength,
  );
}

/// K-weighting filters and 100 ms energy bins for every channel.
class _Accumulator {
  final int channels;
  final int _subBlockFrames;

  // Stage 1 (high shelf, head effects) and stage 2 (RLB high pass)
  // coefficients, computed for the actual sample rate (as libebur128 does).
  late final double _b0, _b1, _b2, _a1, _a2;
  late final double _hb0, _hb1, _hb2, _ha1, _ha2;
  late final Float64List _z; // 4 filter states per channel

  final List<double> _subBlocks = []; // summed channel energy per 100 ms
  double _subSum = 0;
  int _frameInSub = 0;
  int _channel = 0;

  final int _sampleRate;
  final _OnsetDetector _onsets;
  double _frameSum = 0;

  _Accumulator(this.channels, int sampleRate)
    : _subBlockFrames = (sampleRate / 10).round(),
      _sampleRate = sampleRate,
      _onsets = _OnsetDetector(sampleRate) {
    _z = Float64List(channels * 4);

    var f0 = 1681.974450955533;
    const g = 3.999843853973347;
    var q = 0.7071752369554196;
    var k = math.tan(math.pi * f0 / sampleRate);
    final vh = math.pow(10.0, g / 20.0).toDouble();
    final vb = math.pow(vh, 0.4996667741545416).toDouble();
    var a0 = 1.0 + k / q + k * k;
    _b0 = (vh + vb * k / q + k * k) / a0;
    _b1 = 2.0 * (k * k - vh) / a0;
    _b2 = (vh - vb * k / q + k * k) / a0;
    _a1 = 2.0 * (k * k - 1.0) / a0;
    _a2 = (1.0 - k / q + k * k) / a0;

    f0 = 38.13547087602444;
    q = 0.5003270373238773;
    k = math.tan(math.pi * f0 / sampleRate);
    a0 = 1.0 + k / q + k * k;
    _hb0 = 1.0;
    _hb1 = -2.0;
    _hb2 = 1.0;
    _ha1 = 2.0 * (k * k - 1.0) / a0;
    _ha2 = (1.0 - k / q + k * k) / a0;
  }

  void add(double x) {
    final s = _channel * 4;
    // Direct form II transposed, one stage after the other.
    final y1 = _b0 * x + _z[s];
    _z[s] = _b1 * x - _a1 * y1 + _z[s + 1];
    _z[s + 1] = _b2 * x - _a2 * y1;
    final y2 = _hb0 * y1 + _z[s + 2];
    _z[s + 2] = _hb1 * y1 - _ha1 * y2 + _z[s + 3];
    _z[s + 3] = _hb2 * y1 - _ha2 * y2;
    _subSum += y2 * y2;
    _frameSum += x;

    if (++_channel == channels) {
      _channel = 0;
      _onsets.addFrame(_frameSum / channels);
      _frameSum = 0;
      if (++_frameInSub == _subBlockFrames) {
        _subBlocks.add(_subSum / _subBlockFrames);
        _subSum = 0;
        _frameInSub = 0;
      }
    }
  }

  static double _lufs(double energy) => -0.691 + 10 * math.log(energy) / math.ln10;

  /// [integrated] plus the music span. A 100 ms bin counts as silence only
  /// when it is near-silent (below -60 LUFS, and 45 LU under the song's own
  /// level), so fade-ins, reverb tails and quiet passages stay music.
  LoudnessAnalysis? analysis() {
    final lufs = integrated();
    if (lufs == null) return null;
    final threshold = math.min(-60.0, lufs - 45);
    var first = -1;
    var last = -1;
    for (var i = 0; i < _subBlocks.length; i++) {
      final e = _subBlocks[i];
      if (e > 0 && _lufs(e) > threshold) {
        if (first < 0) first = i;
        last = i;
      }
    }
    final length =
        _subBlocks.length / 10 + _frameInSub / _sampleRate;
    final onsets = _onsets.onsets();
    if (first < 0) {
      return LoudnessAnalysis(
        lufs: lufs,
        musicStart: 0,
        musicEnd: length,
        length: length,
        onsetsMs: onsets,
      );
    }
    return LoudnessAnalysis(
      lufs: lufs,
      musicStart: first / 10,
      musicEnd: math.min(length, (last + 1) / 10),
      length: length,
      onsetsMs: onsets,
    );
  }

  double? integrated() {
    if (_subBlocks.length < 4) return null;
    // 400 ms blocks with 75% overlap = four consecutive 100 ms bins.
    final blocks = <double>[];
    for (var i = 0; i + 4 <= _subBlocks.length; i++) {
      final e = (_subBlocks[i] +
              _subBlocks[i + 1] +
              _subBlocks[i + 2] +
              _subBlocks[i + 3]) /
          4;
      if (e > 0 && _lufs(e) > -70) blocks.add(e);
    }
    if (blocks.isEmpty) return null;
    final relativeGate = _lufs(blocks.reduce((a, b) => a + b) / blocks.length) - 10;
    var sum = 0.0;
    var n = 0;
    for (final e in blocks) {
      if (_lufs(e) > relativeGate) {
        sum += e;
        n++;
      }
    }
    return n == 0 ? null : _lufs(sum / n);
  }
}

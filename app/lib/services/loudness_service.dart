import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:peerm_ytdlp/peerm_ytdlp.dart';

import '../models/song.dart';
import 'debug_log.dart';
import 'loudness_meter.dart';
import 'recommendation_service.dart';

/// Per-song loudness normalisation.
///
/// Each song is measured once (integrated loudness, EBU R128 / BS.1770) and
/// the result is stored in `loudness.json`, keyed by YouTube video id when
/// there is one so a stream and its library copy share a measurement.
/// Playback then scales the song's volume towards [targetLufs].
///
/// The same pass also finds where the music starts and stops
/// ([LoudnessAnalysis]), which playback uses to skip silent intros and outros.
///
/// Measuring needs the whole file decoded to PCM: Windows uses the bundled
/// libmpv (its `pcm` audio output writes a WAV as fast as it can decode),
/// Android uses the platform decoder through the peerm_ytdlp plugin. Both run
/// off the UI thread, one song at a time.
class LoudnessService {
  LoudnessService._();

  /// Where songs are levelled to. -14 LUFS is what YouTube and Spotify use.
  static const double targetLufs = -14.0;

  /// Most modern masters sit around -8 to -11 LUFS and get turned down; very
  /// quiet ones get at most this much lift, and only up to full volume.
  static const double maxBoostDb = 6.0;
  static const double maxCutDb = 15.0;

  static final Map<String, double> _lufs = {};
  static final Map<String, LoudnessAnalysis> _spans = {};

  /// Songs measured before onsets were recorded: their level and span stay
  /// in use, and they are measured once more for the onsets.
  static final Set<String> _needsOnsets = {};

  /// Bumped when the silence rule changes, so older spans are found again.
  static const int _spanVersion = 2;

  /// Bumped when the onset rule changes: songs with older onsets keep their
  /// level and span and are measured once more. (2: pitched onsets only;
  /// version 1 also took drum hits.)
  static const int _onsetVersion = 2;
  static final Map<String, Future<double?>> _inFlight = {};
  static Future<void>? _loading;
  static File? _storeFile;
  static Future<void> _queue = Future.value();
  static Timer? _saveTimer;

  @visibleForTesting
  static void resetForTesting() {
    _lufs.clear();
    _spans.clear();
    _needsOnsets.clear();
    _onsetDurations.clear();
    _inFlight.clear();
    _loading = null;
    _storeFile = null;
    _queue = Future.value();
  }

  @visibleForTesting
  static void setForTesting(String key, double lufs) => _lufs[key] = lufs;

  @visibleForTesting
  static void setSpanForTesting(String key, LoudnessAnalysis analysis) {
    _lufs[key] = analysis.lufs;
    _spans[key] = analysis;
    _onsetDurations.remove(key);
  }

  /// Platforms that can decode a song for measuring.
  static bool get isSupported =>
      debugSupportedOverride ??
      (!kIsWeb && (Platform.isWindows || Platform.isAndroid));

  /// Lets tests pick whether this platform can measure, wherever they run.
  @visibleForTesting
  static bool? debugSupportedOverride;

  static String keyFor(Song song) =>
      RecommendationService.extractVideoId(song.id) ??
      RecommendationService.extractVideoId(song.fileName) ??
      song.id;

  static Future<void> load() => _loading ??= _load();

  static Future<void> _load() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File(p.join(dir.path, 'loudness.json'));
      _storeFile = file;
      if (!await file.exists()) return;
      final data = jsonDecode(await file.readAsString());
      if (data is Map) {
        for (final entry in data.entries) {
          final key = entry.key;
          final v = entry.value;
          if (key is! String) continue;
          // Older builds stored only the loudness, as a bare number.
          if (v is num) {
            _lufs[key] = v.toDouble();
          } else if (v is Map && v['lufs'] is num) {
            final lufs = (v['lufs'] as num).toDouble();
            _lufs[key] = lufs;
            final start = v['start'], end = v['end'], len = v['len'];
            if (start is num && end is num && len is num &&
                v['v'] == _spanVersion) {
              final onsets = v['on'];
              _spans[key] = LoudnessAnalysis(
                lufs: lufs,
                musicStart: start.toDouble(),
                musicEnd: end.toDouble(),
                length: len.toDouble(),
                onsetsMs: onsets is String ? decodeOnsets(onsets) : const [],
              );
              if (onsets is! String || v['ov'] != _onsetVersion) {
                _needsOnsets.add(key);
              }
            }
          }
        }
      }
    } catch (e) {
      DebugLog.write('[loudness] could not read loudness.json: $e');
    }
  }

  static void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () async {
      final file = _storeFile;
      if (file == null) return;
      try {
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsString(jsonEncode({
          for (final e in _lufs.entries)
            e.key: switch (_spans[e.key]) {
              final span? => {
                  'lufs': e.value,
                  'start': span.musicStart,
                  'end': span.musicEnd,
                  'len': span.length,
                  'v': _spanVersion,
                  if (!_needsOnsets.contains(e.key)) ...{
                    'on': encodeOnsets(span.onsetsMs),
                    'ov': _onsetVersion,
                  },
                },
              null => e.value,
            },
        }));
        await tmp.rename(file.path);
      } catch (e) {
        DebugLog.write('[loudness] could not save loudness.json: $e');
      }
    });
  }

  /// The stored loudness of [song], or null if it has not been measured.
  static double? lufsFor(Song song) => _lufs[keyFor(song)];

  /// Where the music in [song] starts and stops, or null if not known yet.
  static LoudnessAnalysis? spanFor(Song song) => _spans[keyFor(song)];

  /// True once [song] has its loudness, its music span and its onsets.
  static bool isMeasured(Song song) {
    final key = keyFor(song);
    return _spans.containsKey(key) && !_needsOnsets.contains(key);
  }

  /// Where the level in the voice range jumps up in [song] (see
  /// [LoudnessAnalysis.onsetsMs]), or null until it has been measured.
  static List<Duration>? onsetsFor(Song song) {
    final key = keyFor(song);
    final span = _spans[key];
    if (span == null || _needsOnsets.contains(key)) return null;
    return _onsetDurations[key] ??= [
      for (final ms in span.onsetsMs) Duration(milliseconds: ms),
    ];
  }

  static final Map<String, List<Duration>> _onsetDurations = {};

  /// Onsets stored compactly: the gaps between them in 10 ms steps, as
  /// little-endian 16-bit numbers in base64 (a few KB per song).
  @visibleForTesting
  static String encodeOnsets(List<int> onsetsMs) {
    final bytes = ByteData(onsetsMs.length * 2);
    var previous = 0;
    for (var i = 0; i < onsetsMs.length; i++) {
      final step = ((onsetsMs[i] - previous) / 10).round().clamp(0, 0xFFFF);
      bytes.setUint16(i * 2, step, Endian.little);
      previous += step * 10;
    }
    return base64Encode(bytes.buffer.asUint8List());
  }

  @visibleForTesting
  static List<int> decodeOnsets(String encoded) {
    try {
      final bytes = ByteData.sublistView(base64Decode(encoded));
      final result = <int>[];
      var at = 0;
      for (var i = 0; i + 1 < bytes.lengthInBytes; i += 2) {
        at += bytes.getUint16(i, Endian.little) * 10;
        result.add(at);
      }
      return result;
    } catch (_) {
      return const [];
    }
  }

  /// Volume multiplier that brings [lufs] to [targetLufs]. Values above 1.0
  /// are a lift, which playback can only apply while the user volume leaves
  /// room for it.
  static double gainForLufs(double? lufs) {
    if (lufs == null) return 1.0;
    final db = (targetLufs - lufs).clamp(-maxCutDb, maxBoostDb);
    return math.pow(10, db / 20).toDouble();
  }

  /// The measured gain for [song], or null until it has been measured.
  static double? gainFor(Song song) {
    final lufs = lufsFor(song);
    return lufs == null ? null : gainForLufs(lufs);
  }

  /// Where most songs land when nothing is known about them yet: the median
  /// of everything measured so far (so it follows the listener's own music),
  /// or a typical modern master before there is enough to go on.
  static double get typicalLufs {
    if (_lufs.length < 5) return defaultTypicalLufs;
    final sorted = _lufs.values.toList()..sort();
    return sorted[sorted.length ~/ 2].clamp(-18.0, -6.0);
  }

  static const double defaultTypicalLufs = -9.0;

  /// The gain to start [song] at: its own when measured, otherwise the
  /// typical one, so the level only needs a small correction once the song
  /// has been measured instead of a clearly audible drop a few seconds in.
  /// Platforms that can never measure keep songs as they are.
  static double startGainFor(Song song) =>
      gainFor(song) ?? (isSupported ? gainForLufs(typicalLufs) : 1.0);

  /// Measures [song] from the finished audio file at [path] unless it is
  /// already known (songs measured by older builds are measured again once,
  /// to find their music span). Safe to call repeatedly: one measurement per song, one
  /// song at a time.
  static Future<double?> measure(Song song, String path) async {
    if (!isSupported) return null;
    await load();
    final key = keyFor(song);
    final known = _lufs[key];
    if (known != null &&
        _spans.containsKey(key) &&
        !_needsOnsets.contains(key)) {
      return known;
    }
    final running = _inFlight[key];
    if (running != null) return running;

    final completer = Completer<double?>();
    _inFlight[key] = completer.future;
    _queue = _queue.then((_) async {
      LoudnessAnalysis? result;
      final sw = Stopwatch()..start();
      try {
        result = await _measureFile(path);
      } catch (e) {
        DebugLog.write('[loudness] measuring "${song.title}" failed: $e');
      }
      if (result != null) {
        _lufs[key] = result.lufs;
        _spans[key] = result;
        _needsOnsets.remove(key);
        _onsetDurations.remove(key);
        _scheduleSave();
        DebugLog.write(
          '[loudness] "${song.title}" = ${result.lufs.toStringAsFixed(1)} LUFS, '
          'music ${result.musicStart.toStringAsFixed(1)}s to '
          '${result.musicEnd.toStringAsFixed(1)}s of '
          '${result.length.toStringAsFixed(1)}s (${sw.elapsedMilliseconds}ms)',
        );
      }
      _inFlight.remove(key);
      completer.complete(result?.lufs ?? known);
    });
    return completer.future;
  }

  @visibleForTesting
  static bool decodeWithMpvForTesting(String dll, String input, String output) =>
      _decodeWithMpv(dll, input, output);

  /// Longer than the longest crossfade (12 s) plus the song's load.
  static const Duration _androidSettle = Duration(seconds: 14);

  static Future<LoudnessAnalysis?> _measureFile(String path) async {
    if (!await File(path).exists()) return null;
    final tmpDir = await getTemporaryDirectory();
    final wav = p.join(
      tmpDir.path,
      'peerm_loudness_${DateTime.now().microsecondsSinceEpoch}.wav',
    );
    try {
      if (Platform.isWindows) {
        final dll = p.join(p.dirname(Platform.resolvedExecutable), 'libmpv-2.dll');
        if (!await File(dll).exists()) return null;
        return await Isolate.run(() {
          if (!_decodeWithMpv(dll, path, wav)) return null;
          return LoudnessMeter.analyzeWav(wav);
        });
      }
      // On phones the decode shares the platform codec service with
      // playback. Starting it mid song change (while the next song loads and
      // a crossfade tail is still playing) made the handover stutter, so let
      // the transition settle first. The song meanwhile plays at the typical
      // level.
      await Future<void>.delayed(_androidSettle);
      final ok = await ytDlpChannel.invokeMethod<bool>('decodeToWav', {
        'input': path,
        'output': wav,
      });
      if (ok != true) return null;
      return await Isolate.run(() => LoudnessMeter.analyzeWav(wav));
    } finally {
      try {
        final f = File(wav);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }
}

// Minimal libmpv bindings: just enough to decode one file to a WAV.
typedef _CreateC = Pointer<Void> Function();
typedef _SetOptionC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _SetOptionDart = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _HandleIntC = Int32 Function(Pointer<Void>);
typedef _HandleIntDart = int Function(Pointer<Void>);
typedef _CommandC = Int32 Function(Pointer<Void>, Pointer<Pointer<Utf8>>);
typedef _CommandDart = int Function(Pointer<Void>, Pointer<Pointer<Utf8>>);
typedef _WaitEventC = Pointer<_MpvEvent> Function(Pointer<Void>, Double);
typedef _WaitEventDart = Pointer<_MpvEvent> Function(Pointer<Void>, double);
typedef _DestroyC = Void Function(Pointer<Void>);
typedef _DestroyDart = void Function(Pointer<Void>);

final class _MpvEvent extends Struct {
  @Int32()
  external int eventId;
  @Int32()
  external int error;
  @Uint64()
  external int replyUserdata;
  external Pointer<Void> data;
}

final class _MpvEndFile extends Struct {
  @Int32()
  external int reason;
  @Int32()
  external int error;
}

const _mpvEventShutdown = 1;
const _mpvEventEndFile = 7;
const _mpvEndFileReasonError = 4;

/// Decodes (up to the first 20 minutes of) [input] to a 16-bit stereo 24 kHz WAV at [output] with its own
/// libmpv instance and the `pcm` audio output. Runs in a background isolate:
/// it blocks until the file is done (well under a second for a song).
bool _decodeWithMpv(String dllPath, String input, String output) {
  final lib = DynamicLibrary.open(dllPath);
  final create = lib.lookupFunction<_CreateC, _CreateC>('mpv_create');
  final setOption = lib.lookupFunction<_SetOptionC, _SetOptionDart>('mpv_set_option_string');
  final initialize = lib.lookupFunction<_HandleIntC, _HandleIntDart>('mpv_initialize');
  final command = lib.lookupFunction<_CommandC, _CommandDart>('mpv_command');
  final waitEvent = lib.lookupFunction<_WaitEventC, _WaitEventDart>('mpv_wait_event');
  final destroy = lib.lookupFunction<_DestroyC, _DestroyDart>('mpv_terminate_destroy');

  final handle = create();
  if (handle == nullptr) return false;
  final strings = <Pointer<Utf8>>[];
  Pointer<Utf8> s(String v) {
    final ptr = v.toNativeUtf8();
    strings.add(ptr);
    return ptr;
  }

  final args = calloc<Pointer<Utf8>>(3);
  try {
    const options = {
      'config': 'no',
      'ao': 'pcm',
      'ao-pcm-waveheader': 'yes',
      'vid': 'no',
      'sid': 'no',
      'audio-display': 'no',
      'untimed': 'yes',
      'audio-format': 's16',
      'audio-channels': 'stereo',
      'audio-samplerate': '24000',
      // Twenty minutes is plenty to judge a song; hour-long mixes would
      // otherwise write a WAV of several hundred MB.
      'end': '1200',
      'terminal': 'no',
    };
    for (final e in options.entries) {
      if (setOption(handle, s(e.key), s(e.value)) < 0) return false;
    }
    if (setOption(handle, s('ao-pcm-file'), s(output)) < 0) return false;
    if (initialize(handle) < 0) return false;
    args[0] = s('loadfile');
    args[1] = s(input);
    args[2] = nullptr;
    if (command(handle, args) < 0) return false;

    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while (DateTime.now().isBefore(deadline)) {
      final event = waitEvent(handle, 0.5).ref;
      if (event.eventId == _mpvEventShutdown) return false;
      if (event.eventId == _mpvEventEndFile) {
        if (event.data == nullptr) return true;
        return event.data.cast<_MpvEndFile>().ref.reason != _mpvEndFileReasonError;
      }
    }
    return false;
  } finally {
    // Destroying the instance closes the WAV and writes its final sizes.
    destroy(handle);
    calloc.free(args);
    for (final ptr in strings) {
      calloc.free(ptr);
    }
  }
}

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
  static final Map<String, Future<double?>> _inFlight = {};
  static Future<void>? _loading;
  static File? _storeFile;
  static Future<void> _queue = Future.value();
  static Timer? _saveTimer;

  @visibleForTesting
  static void resetForTesting() {
    _lufs.clear();
    _inFlight.clear();
    _loading = null;
    _storeFile = null;
    _queue = Future.value();
  }

  @visibleForTesting
  static void setForTesting(String key, double lufs) => _lufs[key] = lufs;

  /// Platforms that can decode a song for measuring.
  static bool get isSupported =>
      !kIsWeb && (Platform.isWindows || Platform.isAndroid);

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
          final v = entry.value;
          if (entry.key is String && v is num) {
            _lufs[entry.key as String] = v.toDouble();
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
        await tmp.writeAsString(jsonEncode(_lufs));
        await tmp.rename(file.path);
      } catch (e) {
        DebugLog.write('[loudness] could not save loudness.json: $e');
      }
    });
  }

  /// The stored loudness of [song], or null if it has not been measured.
  static double? lufsFor(Song song) => _lufs[keyFor(song)];

  /// Volume multiplier that brings [lufs] to [targetLufs]. Values above 1.0
  /// are a lift, which playback can only apply while the user volume leaves
  /// room for it.
  static double gainForLufs(double? lufs) {
    if (lufs == null) return 1.0;
    final db = (targetLufs - lufs).clamp(-maxCutDb, maxBoostDb);
    return math.pow(10, db / 20).toDouble();
  }

  static double gainFor(Song song) => gainForLufs(lufsFor(song));

  /// Measures [song] from the finished audio file at [path] unless it is
  /// already known. Safe to call repeatedly: one measurement per song, one
  /// song at a time.
  static Future<double?> measure(Song song, String path) async {
    if (!isSupported) return null;
    await load();
    final key = keyFor(song);
    final known = _lufs[key];
    if (known != null) return known;
    final running = _inFlight[key];
    if (running != null) return running;

    final completer = Completer<double?>();
    _inFlight[key] = completer.future;
    _queue = _queue.then((_) async {
      double? result;
      final sw = Stopwatch()..start();
      try {
        result = await _measureFile(path);
      } catch (e) {
        DebugLog.write('[loudness] measuring "${song.title}" failed: $e');
      }
      if (result != null) {
        _lufs[key] = result;
        _scheduleSave();
        DebugLog.write(
          '[loudness] "${song.title}" = ${result.toStringAsFixed(1)} LUFS '
          '(${sw.elapsedMilliseconds}ms)',
        );
      }
      _inFlight.remove(key);
      completer.complete(result);
    });
    return completer.future;
  }

  @visibleForTesting
  static bool decodeWithMpvForTesting(String dll, String input, String output) =>
      _decodeWithMpv(dll, input, output);

  static Future<double?> _measureFile(String path) async {
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
          return LoudnessMeter.measureWav(wav);
        });
      }
      final ok = await ytDlpChannel.invokeMethod<bool>('decodeToWav', {
        'input': path,
        'output': wav,
      });
      if (ok != true) return null;
      return await Isolate.run(() => LoudnessMeter.measureWav(wav));
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

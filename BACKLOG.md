# Pear Music backlog

Handover notes for the next working session. Latest release: **v6.2.3** (2026-11-24).
The agent cannot hear audio or see a live mobile run, so the owner-ear and real-device checks
below remain open until confirmed on hardware.

## Open owner checks (real run / by ear)

1. **Confirm fast engine, live streams, and visualizer on a real device run:**
   - Fast engine (`innertube_audio_engine.dart`): Windows `--control-port` VOD play succeeded with no `[fast-engine] ... failed` fallback; still check on mobile that first plays feel fast and do not fall back to `yt-dlp` needlessly.
   - Live streams (`live_hls_proxy.dart`): Windows `--control-port` live search/play reached `LIVE at the edge` (`6159 ms`); still open for a 30+ minute listen on Windows and Android, mobile data usage (~1 MB/min expected), rewind + Go live after buffer builds, and link-refresh stability.
   - Visualizer wave: Windows `--control-port` `/viz` verified WASAPI 64-bin capture (`hasNativeFft: true`, ~80-100 Hz frames while playing, `0` frames on pause, clean reconnect on resume); still confirm soft wave / opt-in mini player wave visually at up to 60 fps while unfocused.
   - Real-run coverage for sleep timer, radio/recommendations, queue edits, and crossfade (currently covered by unit tests, not the control port).

## Bigger projects

- **vivo Origin Island** (parked until vivo opens it up). The island only
  shows whitelisted package names. Options if picked up: an opt-in, self-built
  `island` product flavor (never a public release) or the official route through
  vivo's developer platform (`dev.vivo.com.cn`).

## Memory and performance optimizations

Measure before tuning. The last recorded Windows baseline is v4.9.5 (flat at
296 to 311 MB); none of the items below has a v6.2.3 measurement behind it.

1. **Baseline on the current release.** Short automated `--control-port`
   smoke baseline on Flutter 3.44.9 (Windows release, `/playlocal?i=0`,
   `/expand`, `/tab?i=2`, `/pause`, muted and restored):
   `Idle`: WS `178.7 MB`, Priv `207.1 MB`, GPU Shared `32.5 MB`;
   `Playlocal +3s`: WS `200.9 MB`, Priv `223.3 MB`, GPU Shared `40.5 MB`;
   `Expand +5s`: WS `202.7 MB`, Priv `192.4 MB`, GPU Shared `40.9 MB`;
   `Tab2 +5s`: WS `230.0 MB`, Priv `231.3 MB`, GPU Shared `48.1 MB`;
   `Paused +5s`: WS `220.0 MB`, Priv `207.6 MB`, GPU Shared `47.7 MB`.
   Still open for a 30+ minute mixed session (streamed tracks, crossfade on,
   lyrics open, minimize/restore cycle) sampling working set and private bytes
   every 30 s.
2. **Only if the baseline points at Dart heap:** `ArtworkPalette` keeps up to
   96 `_bytesCache` and 128 `_asyncBytesCache` entries. The async entries
   mostly share the same `Uint8List`s, so the real retention is roughly 5 to
   8 MB at 640 px; cutting to 16 entries risks re-decodes while scrolling.

Already done (removed from the list): lifecycle compaction on Android
`paused` / `hidden` plus `onTrimMemory` (`app_controller.dart`,
`home_shell.dart`), `RamAudioBuffer` cap (`maxRamCacheTracks = 4`,
`maxRamCacheBytes = 32 MB` with LRU eviction in `stream_cache_manager.dart`),
`libmpv` audio-only buffer cap (`JustAudioMediaKit.bufferSize = 4 MB` in
`main.dart`), crossfade `_tailPlayer` disposal after fade-out
(`crossfade.dart`), `YtDlpPrewarmer` 5-minute idle timeout
(`ytdlp_prewarmer.dart`), and single-owner image cache limits / background
compaction (`main.dart`, `app_controller.dart`). The only uncovered case is a
Windows window that is occluded but not minimized; low value.

## How the word glow works now (for context)

- Real word timing (LRCLIB enhanced LRC, NetEase yrc) is used as is.
- Otherwise words are estimated from typical singing pace
  (`LyricsService.spansFor`); a line that does not fit its time at that pace
  is "dense" (no held last word, fills 95% of the room). Estimates are then
  snapped to onsets found in the song's voice range during the loudness pass
  (`LoudnessMeter`, `_OnsetDetector`). Onsets must be followed by a pitched
  sound (drums are rejected), a word moves at most 150 ms, and a line with
  more than 1.5 onsets per sung piece keeps the plain estimate. A backward
  pass keeps snapped words at least 80 ms apart.
- Drawing: `LyricsService.glyphTimes` cuts spans into letters (Arabic, Hebrew
  and Indic stay whole); `lyrics_view.dart` fades each letter in over 150 ms
  with a smoothstep, shifted by the user's Highlight delay.
- Onsets are stored in `loudness.json` (compact base64 deltas, `ov` = onset
  rule version); bumping `_onsetVersion` re-measures songs once.
- Saved lyrics carry marks: `[pear:word-timing-checked]`,
  `[pear:source:lrclib|netease|lrclib-manual]`, `[pear:spacing-checked]`.
- Known limits: loud guitar or piano chords can still pass as voice;
  Japanese and Chinese are timed per character; the player skips leading
  silence, so positions jump forward at song start.

## Working notes

- **Toolchain:** Flutter 3.44.9 (what CI uses; 3.47.6 and 3.50.1 were tested
  and rejected for a +317 MB Windows playback RAM regression, and
  `ExcludeSemantics` in `app/lib/main.dart` stays in place). Checks before
  any push: `dart analyze --no-fatal-warnings lib test` and
  `flutter test --no-pub` in `app/`.
- `flutter pub get` regenerates `app/windows/flutter/generated_plugin*`;
  the repo doesn't track them for the app, so don't commit them.
- **Releasing:** bump `app/pubspec.yaml` (`version: X.Y.Z+build`),
  `currentVersion` in `app/lib/services/update_service.dart` and
  `MyAppVersion` in `tool/installer.iss`; commit `release: vX.Y.Z - ...`
  on `main`; then push an annotated tag `vX.Y.Z`, which starts
  `.github/workflows/release.yml`. Tag messages must stay free of quotes and
  apostrophes so they paste into PowerShell.
- **Release notes** leave out build, ci, chore, test and docs commits.
- **Driving a real run without a mouse:** the Windows app takes `--no-focus`
  (shown behind every window, never activated) and `--control-port=<port>
  --control-token=<16+ chars>` for a local control port (127.0.0.1 only; see
  `lib/services/test_control.dart`). Run copies outside `Downloads` (e.g.
  `%LOCALAPPDATA%\Programs\<name>`), set `/volume?v=0` first and restore it,
  then `/quit` and delete the copy.
- **Code layout of the player:** `lib/services/player_service.dart` holds the
  state, getters, init and the audio handler; stream resolution lives in
  `lib/services/player_service/stream_resolver.dart` (`StreamPlaybackResolver`);
  behaviour lives in the mixins in `lib/services/player_service/`.
- **README screenshots:** `flutter test tool/readme_shots/readme_shots_test.dart --update-goldens` in `app/`.
- **Never print or commit real song lyrics** (in tests, renders or chat); use placeholder text.
- LRCLIB, NetEase and YouTube are unreachable from the cloud sandbox; test with fakes and synthetic audio.
- `tool/test_playlists/Pear Lyrics Test.m3u8`: 17 songs covering the lyric sync edge cases.
- **The Windows memory climb is fixed (v4.9.5, 2026-10-18).** Removing the
  blurred drop shadow from `PearGlass` keeps runs flat at 296 to 311 MB.
  Impeller stays unusable (black window on this laptop).

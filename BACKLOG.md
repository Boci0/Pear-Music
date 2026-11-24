# Pear Music backlog

Handover notes for the next working session. Latest release: **v6.2.2** (2026-11-24).
The agent cannot hear audio or see a live mobile run, so the owner-ear and real-device checks
below remain open until confirmed on hardware.

## Open owner checks (real run / by ear)

1. **Confirm fast engine, live streams, and visualizer on a real device run:**
   - Fast engine (`innertube_audio_engine.dart`): check that first plays feel fast on mobile and do not fall back to `yt-dlp` needlessly (`[fast-engine] ... failed` in debug log).
   - Live streams (`live_hls_proxy.dart`): long listen (30+ minutes) on Windows and Android, mobile data usage (~1 MB/min expected), rewind + Go live, and link-refresh stability.
   - Visualizer wave: soft wave on player card and opt-in mini player wave at up to 60 fps while window is visible but unfocused.
   - Real-run coverage for sleep timer, radio/recommendations, queue edits, and crossfade (currently covered by unit tests, not the control port).
2. **Confirm the v4.1.4 to v4.1.7 lyric changes by ear:**
   - Ask the owner how HUMBLE. and Blinding Lights feel (dense rap line pacing, letter-by-letter `glyphTimes`, onset snapping, Highlight delay slider `-500..+500 ms`, `NeteaseLyrics.respaced` spacing restoration).
3. **First line far off on Blinding Lights (NetEase):**
   - NetEase stamps the opening "Yeah" around 0:23 instead of 0:14 (likely timed to a different recording within the +-3 s length tolerance). Options if more songs show this: pick an LRCLIB version by hand, add a first-line vocal-onset audio check, or implement speech-model alignment below.
4. **Lyric timing reports from v4.1.x** still awaiting a Report timing snapshot (Lyrics Options) or owner feedback:
   - HUMBLE. (Kendrick Lamar, hand-picked LRCLIB without word timing), Guitar to Kodoku to Aoi Hoshi (Kessoku Band), Yoru ni Kakeru (YOASOBI), Hype Boy (NewJeans), Idol (YOASOBI), Lemon (Kenshi Yonezu; no real word timing from either source). Treat non-English tracks as unverified until checked by a fluent listener.

## Bigger projects

- **Upgrade past Flutter 3.44.9 and restore Windows semantics.** v6.2.2 wraps
  `MaterialApp` in `ExcludeSemantics` on Windows (`app/lib/main.dart`) to stop
  `flutter_windows.dll` crashing in
  `AccessibilityBridge::CreateRemoveReparentedNodesUpdate` (`0xc0000005` under
  Windows UI Automation or window-inspection queries during widget updates).
  Move the local pin and `.github/workflows/release.yml` to a newer Flutter
  stable once upstream includes the C++ null-parent fix in
  `accessibility_bridge.cc`, verify under active UIA inspection during
  playback, and remove the `ExcludeSemantics` workaround.
- **Speech-model alignment for word timing** (Windows first). Align known lyric
  text to the decoded audio with a small model (Whisper word timestamps or a
  CTC forced aligner), reusing the PCM decode the loudness pass already does.
  Costs: roughly 40 to 150 MB download, seconds per song on a PC, more on
  phones, weaker under loud instruments without vocal separation. Keep the
  current estimate as the fallback until a song is aligned.
- **vivo Origin Island** (parked until vivo opens it up). The island only
  shows whitelisted package names. Options if picked up: an opt-in, self-built
  `island` product flavor (never a public release) or the official route through
  vivo's developer platform (`dev.vivo.com.cn`).

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

- **Toolchain:** Flutter 3.44.9 (what CI uses). Checks before any push:
  `dart analyze --no-fatal-warnings lib test` and `flutter test --no-pub` in `app/`.
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

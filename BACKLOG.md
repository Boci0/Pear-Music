# Pear Music backlog

Handover notes for the next working session. Latest release: **v4.6.1** (2026-10-12, internal only:
the player code split into files, no visible change). The lyric items below were written at v4.1.7 and
have not been re-confirmed since (verified only by tests and the owner's reports; the agent cannot hear
audio, but it can drive the Windows build through the control port, see Working notes).

## Start here

1. **Confirm the v4.5.0 and v4.6.0 changes on a real run.** Covered by tests
   and the control port only, not yet confirmed by the owner. A control port
   run of the v4.6.1 Windows build (2026-10-12) did pass: local playback,
   pause, seek, next, previous, a song ending on its own, one cached stream,
   and one live stream rewound 120 s and returned with Go live, with no
   errors in the log. It cannot judge sound, the phone, or a long listen:
   - Fast engine (v4.5.0): songs are fetched by the built-in InnerTube engine
     first (`innertube_audio_engine.dart`) and start after the first couple
     of megabytes; yt-dlp handles whatever it can't. Check that first plays
     are faster on a phone and that nothing falls back to yt-dlp needlessly
     (the debug log notes `[fast-engine] ... failed` when it gives up on a song).
   - Live streams (v4.5.0, v4.6.0): play through `live_hls_proxy.dart`, are
     marked LIVE everywhere, have a Live pill in Explore, can be rewound by
     as much as YouTube keeps (about an hour) and return to live with Go
     live; a refused or expired link is replaced instead of ending the
     stream. Check a long listen (30+ minutes) on both Windows and a phone,
     and the mobile data figure (about 1 MB a minute expected).
   - Visualizer wave (v4.5.0, v4.6.0): one soft wave on the player card and
     an opt-in thin wave on the mini player (off by default, it costs
     battery). The mini player wave should run at up to 60 fps and keep
     moving while the window is visible but not in front.
2. **Confirm the v4.1.4 to v4.1.7 lyric changes by ear.** Nothing below was
   heard by the agent. Ask the owner how HUMBLE. and Blinding Lights feel now:
   - v4.1.4: a line too long for its time (rap) is sung nonstop, no held last
     word, fills 95% of the time (the glow used to run ahead).
   - v4.1.5: the glow travels through the letters (`glyphTimes`) instead of
     lighting a word as a block; words no longer pile onto one instant when
     onset snapping shifts a line late.
   - v4.1.6: a word's first letter lights exactly on the word start, the rest
     within 60% of the word and 300 ms, 150 ms fade, no built-in delay; a
     **Highlight delay slider** (-500 to +500 ms, `LyricsDisplay.glowDelayMs`) in
     Lyrics Options moves only the glow. It is also in the timing report.
   - v4.1.7: words glued together in NetEase word data ("I'mgoing") get their
     spaces back from NetEase's plain lyrics when the letters match exactly
     (`NeteaseLyrics.respaced`); older saved lyrics are refetched once
     (`[pear:spacing-checked]`). Not yet confirmed on the real song.
3. **First line far off on Blinding Lights (NetEase).** The report shows the
   line data itself is late: the "Yeah" the owner hears at 0:14 is stamped
   about 0:23 in NetEase's data (the rest of the song is mostly fine). Likely
   NetEase timed to a slightly different recording than the YouTube one (the
   length check only allows +-3 s). Not an app bug, so no fix yet. Options,
   in order: pick an LRCLIB version by hand; a first-line-only audio check
   (pull the line earlier when the loudness pass sees a vocal onset far before
   its stamp; a guess, could misfire on long instrumental intros); or real
   alignment (below). Wait for more reports before building the check.
4. **Lyric timing failures reported on v4.1.x** still need a Report timing
   (Lyrics Options) or at least "whole line early/late" vs "glow drifts
   within the line" (issue form: `.github/ISSUE_TEMPLATE/lyric-timing.yml`):
   - HUMBLE. (Kendrick Lamar): glow ran ahead (fixed in 4.1.4, unconfirmed).
     Its lyrics were picked by hand from LRCLIB, which has no word timing and
     is never replaced by NetEase, so it stays on the estimate.
   - Guitar to Kodoku to Aoi Hoshi (Kessoku Band)
   - Yoru ni Kakeru (YOASOBI)
   - Hype Boy (NewJeans)
   - Idol (YOASOBI): timing off (its mixed romanized lines are fixed in 4.1.2)
   - Lemon (Kenshi Yonezu): no real word timing from either source, so it
     is on the estimate; likely a source limit, not an app bug.
   The owner can't judge Japanese, Chinese or Korean lyrics, so treat those
   as unverified rather than failed. Saved lyrics record their source
   (`[pear:source:...]`); lyrics saved before 4.1.3 report it as unknown.
5. **Idea, not built:** a "Try NetEase word timing" button in Lyrics Options
   so a hand-picked LRCLIB version can borrow real word timing when NetEase
   has it and fits the song length.

## Bigger projects

- **Speech-model alignment for word timing** (Windows first). The only
  approach that truly follows the voice: align the known lyric text to the
  audio with a small model (Whisper word timestamps or a CTC forced
  aligner), reusing the PCM decode the loudness pass already does. Costs:
  roughly 40 to 150 MB download, seconds per song on a PC, more on phones,
  weaker under loud instruments without vocal separation. Keep the current
  estimate as the fallback until a song is aligned.
- **vivo Origin Island** (parked until vivo opens it up). The island only
  shows whitelisted package names. Confirmed by the owner: an app re-signed
  with Apple Music's package id (`com.apple.android.music`) appears on it.
  Options if picked up: an opt-in, self-built `island` product flavor with
  that application id (can't coexist with real Apple Music, separate app
  data, needs a flavor-aware updater, never a public release since it
  claims Apple's id), or the official route through vivo's developer
  platform (atomic notification spec at dev.vivo.com.cn, unreachable from
  the cloud sandbox).

## Smaller items

- **Finish splitting `PlayerService`.** v4.6.1 moved the sleep timer into its
  own class (`sleep_timer.dart`) and the crossfade, live, recommendations,
  preload, queue edit and playback code into mixins under
  `lib/services/player_service/` (`part` files). `player_service.dart` is
  about 990 lines. What is left: `playback.dart` is still 1,100+ lines and
  `playSong` alone is about 400 (stream resolution, retries, cache hand-off),
  and the mixins share one library and the player's state, so they are
  files to read, not isolated parts. Next cut: pull stream resolution out of
  `playSong` into its own class with a small interface. Not covered by a
  real run, only by unit tests: sleep timer, radio and recommendations,
  queue edits and crossfade (the control port cannot reach them).
- **Silent `catch (_)` blocks.** The ones where a failure loses data or changes
  what the user gets now write to `debug_log` (library moves, lyric writes,
  history and favourites loading, update and yt-dlp manifest checks, network
  fetches). About 80 remain on purpose: cleanup deletes, process kills,
  optional channel calls and the diagnostics sampler.
- **Android analysis priority.** The loudness and onset analysis runs in a
  normal-priority isolate (the Android decode itself is low priority). If a
  stutter a second or two into a song ever shows up, look here first.

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
  `dart analyze --no-fatal-warnings lib test` and `flutter test` in `app/`.
- `flutter pub get` regenerates `app/windows/flutter/generated_plugin*`;
  the repo doesn't track them for the app, so don't commit them.
- **Releasing:** bump `app/pubspec.yaml` (`version: X.Y.Z+build`),
  `currentVersion` in `app/lib/services/update_service.dart` and
  `MyAppVersion` in `tool/installer.iss`; commit `release: vX.Y.Z - ...`
  on `main`; then push an annotated tag `vX.Y.Z`, which starts
  `.github/workflows/release.yml`. Tag pushes are rejected from the cloud
  sandbox, so the owner pushes the tag. Keep tag messages free of quotes and
  apostrophes so they paste into PowerShell.
- **Release notes** leave out build, ci, chore, test and docs commits. The
  release script no longer limits how often releases are made.
- **Driving a real run without a mouse:** the Windows app takes `--no-focus`
  (shown behind every window, never activated) and `--control-port=<port>
  --control-token=<16+ chars>` for a local control port (127.0.0.1 only; see
  `lib/services/test_control.dart`). It can play a library song, seek a live
  stream and report what the visualizer feed sees.
  **Run a build from outside `Downloads`.** The exe built in
  `app\build\windows\x64\runner\Release` gets "Access is denied" on every
  file write when it runs from the repo under Downloads (preferences, temp
  file, cache), so no song opens. Copy the Release folder to
  `%LOCALAPPDATA%\Programs\<name>`, launch it from there, set `/volume?v=0`
  first and restore the value `/state` reported, then `/quit` and delete the
  copy. From a shell, start it detached with all handles redirected; starting
  it through the PowerShell tool hangs the tool. The build itself needs
  NuGet's temp and cache folders pointed into `app\build\windows\x64` or it
  fails on a lock.
- **Code layout of the player:** `lib/services/player_service.dart` holds the
  state, getters, init and the audio handler; behaviour lives in the mixins
  in `lib/services/player_service/`. A mixin lists what it needs from the
  player at the top of its file and builds on the others with `on`.
- **README screenshots** are rendered offscreen with made-up songs:
  `flutter test tool/readme_shots/readme_shots_test.dart --update-goldens` in
  `app/`. Runs on Linux too; off Windows the desktop shot uses Roboto because
  Segoe UI isn't there. Regenerate them after any visible change to the
  library screen, the side pane or the status bar (which shows the version).
- **Never print or commit real song lyrics** (in tests, renders or chat);
  use placeholder text. A real lyric line once got output blocked.
- LRCLIB, NetEase and YouTube are unreachable from the cloud sandbox;
  test with fakes and synthetic audio.
- `tool/test_playlists/Pear Lyrics Test.m3u8`: 17 songs covering the lyric
  sync edge cases (fast rap, J-rock, CJK, ballads, an instrumental). Import
  it through the app; entries are resolved online by title.

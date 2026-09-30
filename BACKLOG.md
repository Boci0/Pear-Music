# Pear Music backlog

Handover notes for the next working session. Latest release: **v4.1.7** (all verified only by tests and the
owner's reports; the agent cannot hear audio or run the app).

## Start here

1. **Confirm the v4.1.4 to v4.1.7 lyric changes by ear.** Nothing below was
   heard by the agent. Ask the owner how HUMBLE. and Blinding Lights feel now:
   - v4.1.4: a line too long for its time (rap) is sung nonstop, no held last
     word, fills 95% of the time (the glow used to run ahead).
   - v4.1.5: the glow travels through the letters (`glyphTimes`) instead of
     lighting a word as a block; words no longer pile onto one instant when
     onset snapping shifts a line late.
   - v4.1.6: a word's first letter lights exactly on the word start, the rest
     within 60% of the word and 300 ms, 150 ms fade, no built-in delay; a
     **Glow timing slider** (-500 to +500 ms, `LyricsDisplay.glowDelayMs`) in
     Lyrics Options moves only the glow. It is also in the timing report.
   - v4.1.7: words glued together in NetEase word data ("I'mgoing") get their
     spaces back from NetEase's plain lyrics when the letters match exactly
     (`NeteaseLyrics.respaced`); older saved lyrics are refetched once
     (`[pear:spacing-checked]`). Not yet confirmed on the real song.
2. **First line far off on Blinding Lights (NetEase).** The report shows the
   line data itself is late: the "Yeah" the owner hears at 0:14 is stamped
   about 0:23 in NetEase's data (the rest of the song is mostly fine). Likely
   NetEase timed to a slightly different recording than the YouTube one (the
   length check only allows +-3 s). Not an app bug, so no fix yet. Options,
   in order: pick an LRCLIB version by hand; a first-line-only audio check
   (pull the line earlier when the loudness pass sees a vocal onset far before
   its stamp; a guess, could misfire on long instrumental intros); or real
   alignment (below). Wait for more reports before building the check.
3. **Lyric timing failures reported on v4.1.x** still need a Report timing
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
4. **Idea, not built:** a "Try NetEase word timing" button in Lyrics Options
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

- **Artist for downloaded songs.** `Song.artist` is filled for online songs
  (v4.1.3) and shown on its own line in media controls. Songs saved to the
  library and favorites restored from an import do not carry it yet.
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
  with a smoothstep, shifted by the user's Glow timing.
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
- `growing_file_audio_source_test` failed once under a full-suite run and
  passes alone (timing flake, unrelated to lyrics).
- **Never print or commit real song lyrics** (in tests, renders or chat);
  use placeholder text. A real lyric line once got output blocked.
- LRCLIB, NetEase and YouTube are unreachable from the cloud sandbox;
  test with fakes and synthetic audio.
- `tool/test_playlists/Pear Lyrics Test.m3u8`: 17 songs covering the lyric
  sync edge cases (fast rap, J-rock, CJK, ballads, an instrumental). Import
  it through the app; entries are resolved online by title.

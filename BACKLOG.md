# Pear Music backlog

Handover notes for the next working session. Latest release: **v4.1.3**.

## Start here

1. **Lyric timing failures reported on v4.1.x.** v4.1.3 added a "Report
   timing" button (Lyrics Options) and a GitHub issue form
   (`.github/ISSUE_TEMPLATE/lyric-timing.yml`). Each of these needs a report
   from the button, or at least "whole line early/late" vs "glow drifts
   within the line":
   - HUMBLE. (Kendrick Lamar)
   - Guitar to Kodoku to Aoi Hoshi (Kessoku Band)
   - Yoru ni Kakeru (YOASOBI)
   - Hype Boy (NewJeans)
   - Idol (YOASOBI): timing off (its mixed romanized lines are fixed in 4.1.2)
   - Lemon (Kenshi Yonezu): no real word timing from either source, so it
     is on the estimate; likely a source limit, not an app bug.
   The owner can't judge Japanese, Chinese or Korean lyrics, so treat those
   as unverified rather than failed. Saved lyrics record their source
   (`[pear:source:...]`); lyrics saved before 4.1.3 report it as unknown.

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
  (`LyricsService.spansFor`), then snapped to onsets found in the song's
  voice range during the loudness pass (`LoudnessMeter`, `_OnsetDetector`).
  Onsets must be followed by a pitched sound (drums are rejected), a word
  moves at most 150 ms, and a line with more than 1.5 onsets per sung piece
  (a fast distorted guitar) keeps the plain estimate.
- Onsets are stored in `loudness.json` (compact base64 deltas, `ov` = onset
  rule version); bumping `_onsetVersion` re-measures songs once.
- Known limits: loud guitar or piano chords can still pass as voice;
  Japanese and Chinese are timed per character.

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
- **Never print or commit real song lyrics** (in tests, renders or chat);
  use placeholder text. A real lyric line once got output blocked.
- LRCLIB, NetEase and YouTube are unreachable from the cloud sandbox;
  test with fakes and synthetic audio.
- `tool/test_playlists/Pear Lyrics Test.m3u8`: 17 songs covering the lyric
  sync edge cases (fast rap, J-rock, CJK, ballads, an instrumental). Import
  it through the app; entries are resolved online by title.

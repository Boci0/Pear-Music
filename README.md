# PEAR MUSIC

> A local-first music player and streaming discovery engine for Windows and Android. No cloud, no accounts.

[![Download for Windows](https://img.shields.io/badge/Download-Windows%20Setup-0078D6?style=for-the-badge&logo=windows&logoColor=white)](https://github.com/Boci0/Pear-Music/releases/latest/download/PearMusic-Windows-Setup.exe)
[![Download for Android](https://img.shields.io/badge/Download-Android%20ARM64-3DDC84?style=for-the-badge&logo=android&logoColor=white)](https://github.com/Boci0/Pear-Music/releases/latest/download/PearMusic-Android-arm64.apk)
[![License](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge)](LICENSE)
[![Built with Flutter](https://img.shields.io/badge/Built%20with-Flutter-02569B?style=for-the-badge&logo=flutter&logoColor=white)](https://flutter.dev)

---

## Overview

**Pear Music** is a fast, local-first music player and streaming discovery application with zero cloud storage and no accounts. Play your local audio files, search and stream music with genre discovery chips, and enjoy continuous listening with Endless Play track recommendations.

---

## Key Features

* **Explore & Music Discovery**: Discover trending songs and genre categories with draggable chips, search directly, and stream without accounts. An expanded search scope can include covers and community uploads alongside official audio.
* **Immersive Dynamic Player**: Full-bleed album artwork with ambient gradients extracted from the track art, animated glow accents, and an interactive waveform seek bar with an optional audio visualizer.
* **Synchronized Lyrics**: Real-time line-by-line highlighting from local `.lrc` companion files, with automatic lookups as a fallback, colour options that stay readable on busy artwork, and a live timing sheet for manual sync.
* **Pull-Up Queue & Library Management**: Bottom sheet queue with drag-and-drop reordering, track removal, fast favoriting, and multi-playlist organization.
* **Library Profiles & Playlists**: Export your library and favorites to a portable M3U8 profile and import it on another device; standard M3U8 playlists import and export as well. Android imports keep running in the background and skip songs you already have.
* **Offline-First Playback**: Fast local audio playback from device storage, with automatic fallback to local tracks when offline.
* **Endless Play**: Automatically queues related track recommendations when your current queue finishes, with background pre-buffering so the next track starts quickly.
* **Save to Library & Favorites**: Bookmark streamed tracks and search results into your favorites and playlists with a single tap, with one heart shared across a song's stream, search, and library copies.
* **Listening History**: A History tab keeps the tracks you played in order, local files and online streams side by side, so you can jump back into any of them; clearing it never touches your library.
* **Background & Lockscreen Playback**: Full native media controls (Play/Pause, Next, Previous, Seek) with album artwork on the Android lockscreen, the notification shade, and Windows Media Transport Controls (SMTC). Hardware media keys work on desktop.
* **Sleep Timer & Playback Speed**: Sleep triggers for the end of the track, a countdown, or the end of the queue; playback speed from 0.5x to 2.0x; and loudness normalization to even out volume between tracks.
* **Performance & Diagnostics**: Reduced Effects mode for battery savings, streaming cache management with live usage stats, and a diagnostics console for stream and cache activity.
* **Automated In-App Updates**: Built-in version checks with one-click updates from GitHub releases; the Android updater resumes interrupted downloads, verifies checksums, and installs the APK that matches your device architecture.

---

## Download

Every build for the latest release is listed below and attached to the [releases page](https://github.com/Boci0/Pear-Music/releases/latest).

| Platform | Architecture | Build | Download |
| :--- | :--- | :--- | :--- |
| **Windows 10/11** | x64 | Setup installer (recommended) | [PearMusic-Windows-Setup.exe](https://github.com/Boci0/Pear-Music/releases/latest/download/PearMusic-Windows-Setup.exe) |
| **Windows 10/11** | x64 | Portable ZIP, no installation | [PearMusic-Windows-x64.zip](https://github.com/Boci0/Pear-Music/releases/latest/download/PearMusic-Windows-x64.zip) |
| **Android** | ARM64, most devices | APK | [PearMusic-Android-arm64.apk](https://github.com/Boci0/Pear-Music/releases/latest/download/PearMusic-Android-arm64.apk) |
| **Android** | ARMv7, older 32-bit devices | APK | [PearMusic-Android-armv7.apk](https://github.com/Boci0/Pear-Music/releases/latest/download/PearMusic-Android-armv7.apk) |

### Which file do I need?

* **Windows**: Use the Setup installer. It installs per user without admin rights, adds Start Menu and optional Desktop shortcuts, and registers an uninstaller. Pick the portable ZIP only if you would rather run the app from an extracted folder.
* **Android**: Use the ARM64 APK on any phone from the last decade. The ARMv7 APK is for older 32-bit devices only. You choose once at first install; in-app updates detect your device architecture and download the matching APK automatically.

Verify a download against [`SHA256SUMS`](https://github.com/Boci0/Pear-Music/releases/latest/download/SHA256SUMS) with `Get-FileHash <file> -Algorithm SHA256` on Windows or `sha256sum <file>` on Linux and macOS.

---

## Quick Start (Build from Source)

### Prerequisites

* **Flutter SDK**: Stable channel, 3.44.9 (the version the release pipeline builds with); the project requires Dart 3.12.2+.
* **Windows Development**: Visual Studio 2022 with **Desktop development with C++** workload installed.
* **Android Development**: Android Studio / SDK with compile SDK 37 installed and Java 17+.

### 1. Clone & Fetch Dependencies

```bash
git clone https://github.com/Boci0/Pear-Music.git
cd Pear-Music/app
flutter pub get
```

### 2. Run in Development Mode

```bash
# Windows Desktop
flutter run -d windows

# Android Device / Emulator
flutter run -d android
```

### 3. Run Automated Tests

```bash
flutter test
```

### 4. Build Production Release Binaries

```bash
# Android Split APKs (arm64-v8a, armeabi-v7a, x86_64)
flutter build apk --split-per-abi --release

# Windows Release Binary (x64)
flutter build windows --release
```

Official releases ship the arm64-v8a and armeabi-v7a APKs. The x86_64 APK only matters for emulators and Intel-based devices.

---

## Android Setup & Background Playback

To ensure uninterrupted background playback and persistent media controls on Android (especially on Android 13+ and OEM skins such as Vivo OriginOS / FuntouchOS, Samsung One UI, or Xiaomi HyperOS):

1. **Notification Permissions**:
   * On first launch on Android 13+, accept the notification permission prompt so Pear Music can display media transport controls in the notification drawer and lockscreen.
2. **Battery Optimization (Prevent Background Freezing)**:
   * **Vivo / iQOO**: Navigate to **Settings -> Battery -> Background power consumption management -> Pear Music** and select **Allow high background power consumption**.
   * **Samsung / Pixel / Xiaomi**: Open **App Info -> Battery** and set to **Unrestricted** (or "Don't restrict").
3. **Quick Settings Media Player**:
   * To keep the media player pinned in Quick Settings even when paused, enable **Settings -> Sound & Vibration -> Media -> Pin media player** (on supported Android versions).

---

## Support

Found a bug or have an idea for a feature? [Open an issue](https://github.com/Boci0/Pear-Music/issues).

---

## License

Pear Music is released under the [MIT License](LICENSE).
Copyright (c) 2026 Boci0.

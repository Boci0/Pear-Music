# PEAR MUSIC

> A local-first music player and YouTube discovery engine for Windows and Android. No cloud, no accounts.

[![Download for Windows](https://img.shields.io/badge/Download-Windows%20ZIP-0078D6?style=for-the-badge&logo=windows&logoColor=white)](https://github.com/Boci0/Pear-Music/releases/latest/download/PearMusic-Windows-x64.zip)
[![Download for Android](https://img.shields.io/badge/Download-Android-3DDC84?style=for-the-badge&logo=android&logoColor=white)](https://github.com/Boci0/Pear-Music/releases/latest/download/PearMusic-Android-arm64.apk)
[![License](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge)](LICENSE)
[![Built with Flutter](https://img.shields.io/badge/Built%20with-Flutter-02569B?style=for-the-badge&logo=flutter&logoColor=white)](https://flutter.dev)

---

## Overview

**Pear Music** is a fast, local-first music player and streaming discovery application with zero cloud storage and no accounts. Play your local audio files, search and stream music from YouTube with genre discovery chips, and enjoy continuous listening with Endless Play track recommendations.

---

## Key Features

* **Explore & Music Discovery**: Discover trending songs and genre categories with draggable genre chips, search YouTube music directly, and stream without accounts.
* **Immersive Dynamic Player**: Full-bleed album artwork with ambient gradients extracted from track art, animated glow accents, and an interactive visualizer progress bar.
* **Synchronized Lyrics**: Real-time synchronized lyrics with line-by-line highlighting, supporting local `.lrc` companion files and automatic LRCLIB lookups.
* **Pull-Up Queue & Library Management**: Bottom sheet queue with drag-and-drop reordering, track removal, fast favoriting, and multi-playlist organization.
* **Offline-First Playback**: Fast local audio playback from device storage, with automatic fallback to local tracks when offline.
* **Endless Play**: Automatically queues related track recommendations when your current queue finishes, with background stream preloading to reduce buffering between tracks.
* **Save to Library & Favorites**: Bookmark streamed tracks and search results into your favorites and playlists with a single tap.
* **Background & Lockscreen Playback**: Full native media controls (Play/Pause, Next, Previous, Seek) with album artwork rendered on Android Lockscreen, Notification Shade, and Windows Media Transport Controls (SMTC).
* **Automated In-App Updates**: Built-in version checks and direct 1-click in-app updates from GitHub releases.
* **Live Diagnostics Console**: Integrated diagnostic log viewer and buffer for checking stream and cache activity.
* **Loudness Normalization**: Leveling to reduce sudden volume jumps between tracks on supported platforms.

---

## Download

| Platform | Package | Direct Link |
| :--- | :--- | :--- |
| **Windows (x64)** | `PearMusic-Windows-x64.zip` | [Download Windows ZIP](https://github.com/Boci0/Pear-Music/releases/latest/download/PearMusic-Windows-x64.zip) |
| **Android (ARM64)** | `PearMusic-Android-arm64.apk` | [Download Android ARM64](https://github.com/Boci0/Pear-Music/releases/latest/download/PearMusic-Android-arm64.apk) |
| **Android (ARMv7 32-bit)** | `PearMusic-Android-armv7.apk` | [Download Android ARMv7](https://github.com/Boci0/Pear-Music/releases/latest/download/PearMusic-Android-armv7.apk) |

---

## Quick Start (Build from Source)

### Prerequisites

* **Flutter SDK**: `^3.12.0` (Dart 3.x+)
* **Windows Development**: Visual Studio 2022 with **Desktop development with C++** workload installed.
* **Android Development**: Android Studio / SDK (Target API 34+, Java 17+).

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

# Windows Release Binary
flutter build windows --release
```

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

## License

Pear Music is released under the [MIT License](LICENSE).
Copyright (c) 2026 Boci0.

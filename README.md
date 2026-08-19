# PEAR MUSIC

> A peer-to-peer music sync app for Windows and Android. No cloud, no accounts.

[![Download for Windows](https://img.shields.io/badge/Download-Windows%20ZIP-0078D6?style=for-the-badge&logo=windows&logoColor=white)](https://github.com/Boci0/Pear-Music/releases/latest/download/peerm_app-windows-x64.zip)
[![Download for Android](https://img.shields.io/badge/Download-Android-3DDC84?style=for-the-badge&logo=android&logoColor=white)](https://github.com/Boci0/Pear-Music/releases/latest/download/app-arm64-v8a-release.apk)
[![License](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge)](LICENSE)
[![Built with Flutter](https://img.shields.io/badge/Built%20with-Flutter-02569B?style=for-the-badge&logo=flutter&logoColor=white)](https://flutter.dev)

---

## Overview

**Pear Music** keeps your music library in sync between your own devices, with
no cloud storage and no account. Drop a song on one device and every device you
have paired it with gets a copy and can play it. Built with Flutter for Windows
and Android. The signaling server is embedded in the app, so there is nothing
to install or configure.

---

## Key Features

- **Background & Lockscreen Playback**: Full system media controls (Play/Pause, Next, Previous, Seekbar) and album artwork on Android Lockscreen, Notification Shade, and Windows Media Transport Controls (SMTC).
- **Automated In-App Updates**: Update directly inside the app without browser download blocks or virus warnings.
- **Zero-Warning Setup Script**: Extract `peerm_app-windows-x64.zip` and run `peerm_app.exe` directly.
- **Unified Batch Sync Progress**: Replaces song-tile progress clutter during large initial library syncs with a single, clean top progress banner (`Syncing Library • X of Y songs`).
- **Code-based pairing**: One device shows a 6-character code (or a QR code), the other enters it. That is the whole setup.
- **End-to-end encrypted sync**: Files copy device-to-device over an encrypted relay (AES-256-GCM), so the server cannot read your music and never stores it.
- **Reconnect catch-up**: If a device is offline when you add a song, it pulls what it missed the next time it connects.
- **Unpair removes**: Unpairing a device deletes the songs it received from you (and vice versa). Songs you added yourself stay.
- **Standalone player**: Works as a normal local music player even if you never pair anything.

---

## Download

| Platform | File | Direct Download |
| --- | --- | --- |
| **Windows (x64)** | `peerm_app-windows-x64.zip` | [Download ZIP](https://github.com/Boci0/Pear-Music/releases/latest/download/peerm_app-windows-x64.zip) |
| **Android (ARM64)** | `app-arm64-v8a-release.apk` | [Download APK](https://github.com/Boci0/Pear-Music/releases/latest/download/app-arm64-v8a-release.apk) |
| **Android (ARMv7 32-bit)** | `app-armeabi-v7a-release.apk` | [Download APK](https://github.com/Boci0/Pear-Music/releases/latest/download/app-armeabi-v7a-release.apk) |

---

## Quick Start (Build from Source)

```bash
cd app
flutter pub get
flutter run -d windows        # Windows
flutter run -d <device_id>    # Android
```

---

## License

Pear Music is released under the [MIT License](LICENSE).
Copyright (c) 2026 Boci0.

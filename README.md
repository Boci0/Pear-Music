# PEAR MUSIC

> A peer-to-peer music sync and radio player for Windows and Android. No cloud, no accounts.

[![Download for Windows](https://img.shields.io/badge/Download-Windows%20ZIP-0078D6?style=for-the-badge&logo=windows&logoColor=white)](https://github.com/Boci0/Pear-Music/releases/latest/download/PearMusic-Windows-x64.zip)
[![Download for Android](https://img.shields.io/badge/Download-Android-3DDC84?style=for-the-badge&logo=android&logoColor=white)](https://github.com/Boci0/Pear-Music/releases/latest/download/PearMusic-Android-arm64.apk)
[![License](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge)](LICENSE)
[![Built with Flutter](https://img.shields.io/badge/Built%20with-Flutter-02569B?style=for-the-badge&logo=flutter&logoColor=white)](https://flutter.dev)

---

## Overview

**Pear Music** keeps your music library in sync between your devices with zero cloud storage and no accounts. Drop a song on one device, and paired devices receive and play it seamlessly. Pear Music also includes **Pear Radio**, an ephemeral radio and smart recommendation streaming engine that allows you to discover, stream, and save songs on the fly.

---

## Key Features

* **End-to-End Encrypted Relay Sync**: Fast device-to-device audio file transfer via encrypted relays (AES-256-GCM / X25519). Files are never stored on external servers.
* **Pear Radio & Smart Autoplay**: Infinite stream recommendations based on your listening habits with a 4-track sliding window disk pre-buffer and visual cache indicators for zero-latency skipping.
* **1-Click Save to Library**: Instantly promote any radio stream track into your permanent local library in 0 ms without re-downloading.
* **Background & Lockscreen Playback**: Full native media controls (Play/Pause, Next, Previous, Seek) with ID3/Vorbis album artwork rendered on Android Lockscreen, Notification Shade, and Windows Media Transport Controls (SMTC).
* **Automated In-App Updates**: Seamless version checks and 1-click in-app updates directly from GitHub releases.
* **Fast Code & QR Pairing**: Connect devices in seconds using a 6-character pairing code or QR scan.
* **Live Diagnostics Console**: Integrated diagnostic log viewer and ring buffer for real-time monitoring of sync, relay, stream, and cache activity.
* **Loudness Normalization**: Dynamic range enhancement to prevent jarring volume jumps between tracks.

---

## Download

| Platform | Package | Direct Link |
| :--- | :--- | :--- |
| **Windows (x64)** | `PearMusic-Windows-x64.zip` | [Download Windows ZIP](https://github.com/Boci0/Pear-Music/releases/latest/download/PearMusic-Windows-x64.zip) |
| **Android (ARM64)** | `PearMusic-Android-arm64.apk` | [Download Android ARM64](https://github.com/Boci0/Pear-Music/releases/latest/download/PearMusic-Android-arm64.apk) |
| **Android (ARMv7 32-bit)** | `PearMusic-Android-armv7.apk` | [Download Android ARMv7](https://github.com/Boci0/Pear-Music/releases/latest/download/PearMusic-Android-armv7.apk) |

---

## Quick Start (Build from Source)

```bash
cd app
flutter pub get
flutter run -d windows        # Windows
flutter run -d <device_id>    # Android
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

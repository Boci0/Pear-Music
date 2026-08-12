# PEAR MUSIC

> A peer-to-peer music sync app for Windows and Android. No cloud, no accounts.

[![Download for Windows](https://img.shields.io/badge/Download-Windows-0078D6?style=for-the-badge&logo=windows&logoColor=white)](https://github.com/Boci0/Pear-Music/releases/latest/download/PearMusic-Windows-x64.zip)
[![Download for Android](https://img.shields.io/badge/Download-Android-3DDC84?style=for-the-badge&logo=android&logoColor=white)](https://github.com/Boci0/Pear-Music/releases/latest/download/PearMusic-Android-arm64.apk)
[![Download for Android (ARMv7)](https://img.shields.io/badge/Download-Android%20ARMv7-3DDC84?style=for-the-badge&logo=android&logoColor=white)](https://github.com/Boci0/Pear-Music/releases/latest/download/PearMusic-Android-armv7.apk)
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

- **Code-based pairing**: One device shows a 6-character code (or a QR code),
  the other enters it. That is the whole setup.
- **End-to-end encrypted sync**: Files copy device-to-device over an encrypted
  relay (AES-256-GCM), so the server cannot read your music and never stores it.
- **Reconnect catch-up**: If a device is offline when you add a song, it pulls
  what it missed the next time it connects.
- **Unpair removes**: Unpairing a device deletes the songs it received from you
  (and vice versa). Songs you added yourself stay.
- **Standalone player**: Works as a normal local music player even if you never
  pair anything.

---

## Download

The buttons at the top download the latest build directly. They point at the
release assets, so the [Releases](https://github.com/Boci0/Pear-Music/releases)
page is just the backup if you want a specific version:

| Platform            | File                          | How to run                        |
| ------------------- | ----------------------------- | --------------------------------- |
| **Windows**         | `PearMusic-Windows-x64.zip`   | Extract, then run `peerm_app.exe` |
| **Android**         | `PearMusic-Android-arm64.apk` | Open the file, allow unknown apps |
| **Android (older)** | `PearMusic-Android-armv7.apk` | Open the file, allow unknown apps |

> The Windows binary is not code-signed, so SmartScreen may warn the first time
> you run it. Click "More info", then "Run anyway".

---

## Quick Start (Build from Source)

```bash
cd app
flutter pub get
flutter run -d windows        # Windows
flutter run -d <device-id>    # Android
```

That's it. Devices discover each other on the same network automatically, and
one of them hosts the built-in server, so there is no separate server to run.

The `server/` folder is an optional reference Node.js signaling server, only
needed if you want to host your own relay on the internet instead of using the
embedded one.

---

## Usage

| Action            | How                                                |
| ----------------- | -------------------------------------------------- |
| **Pair a device** | Devices -> Pair a device, share code or scan QR    |
| **Add music**     | Drop a file, tap "+", or paste a link              |
| **Multi-select**  | Long-press a song or tap the checklist icon        |
| **Force sync**    | Devices -> Force Sync or "+" -> Force sync files    |
| **Play**          | Tap a song                                         |
| **Unpair**        | Devices -> remove the device                       |

---

## Architecture

- `app/`: Flutter app (Windows + Android), including the embedded signaling server
- `server/`: optional reference Node.js signaling server (pairing, presence, relay)

---

## Testing

```bash
cd app && flutter test              # app tests
cd server && node test/smoke.js     # optional reference-server tests (needs the server running on :8080)
```

---

## License

[MIT](LICENSE)

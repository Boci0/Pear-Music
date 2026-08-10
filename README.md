# PEAR MUSIC

> A peer-to-peer music sync app for Windows and Android. No cloud, no accounts.

[![Download for Windows](https://img.shields.io/badge/Download-Windows-0078D6?style=for-the-badge&logo=windows&logoColor=white)](https://github.com/Boci0/Pear-Music/releases/latest/download/PearMusic-Windows-x64.zip)
[![Download for Android](https://img.shields.io/badge/Download-Android-3DDC84?style=for-the-badge&logo=android&logoColor=white)](https://github.com/Boci0/Pear-Music/releases/latest/download/PearMusic-Android-arm64.apk)
[![Download for Android (ARMv7)](https://img.shields.io/badge/Download-Android%20ARMv7-3DDC84?style=for-the-badge&logo=android&logoColor=white)](https://github.com/Boci0/Pear-Music/releases/latest/download/PearMusic-Android-armv7.apk)
[![License](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge)](LICENSE)
[![Built with Flutter](https://img.shields.io/badge/Built%20with-Flutter-02569B?style=for-the-badge&logo=flutter&logoColor=white)](https://flutter.dev)
[![Server](https://img.shields.io/badge/Server-Node.js-339933?style=for-the-badge&logo=nodedotjs&logoColor=white)](server/)

---

## Overview

**Pear Music** keeps your music library in sync between your own devices, with
no cloud storage and no account. Drop a song on one device and every device you
have paired it with gets a copy and can play it. Built with Flutter for Windows
and Android, backed by a small Node.js signaling server.

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

| Platform    | File                          | How to run                        |
| ----------- | ----------------------------- | --------------------------------- |
| **Windows** | `PearMusic-Windows-x64.zip`   | Extract, then run `peerm_app.exe` |
| **Android** | `PearMusic-Android-arm64.apk` | Open the file, allow unknown apps |
| **Android (older)** | `PearMusic-Android-armv7.apk` | Open the file, allow unknown apps |

> The Windows binary is not code-signed, so SmartScreen may warn the first time
> you run it. Click "More info", then "Run anyway".

---

## Quick Start (Build from Source)

**Server**

```bash
cd server
npm install
npm start        # listens on :8080
```

**App**

```bash
cd app
flutter pub get
flutter run -d windows        # Windows
flutter run -d <device-id>    # Android
```

Open the app's Settings, point the signaling server URL at your server
(`ws://localhost:8080` if it is the same machine), and give the device a name.

---

## Usage

| Action            | How                                                |
| ----------------- | -------------------------------------------------- |
| **Pair a device** | Devices -> Pair a device, generate or enter a code |
| **Add music**     | Drop a file, use Add music, or paste a link        |
| **Play**          | Tap a song                                         |
| **Unpair**        | Devices, remove the device                         |

---

## Architecture

- `app/`: Flutter client (Windows + Android)
- `server/`: Node.js signaling server (pairing, presence, relay)

---

## Testing

```bash
cd server && node test/smoke.js   # needs the server running on :8080
cd app && flutter test
```

---

## License

[MIT](LICENSE)

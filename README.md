# PeerM

A small app for keeping your music library in sync between your own devices —
no cloud storage, no account. Drop a song on one device and every device you've
paired it with gets a copy and can play it. I made this for my Windows PC and
Android phone, so those are the two platforms I test on.

It's a Flutter app (one codebase) plus a small Node.js signaling server.

## How it works

Pairing is just a code. One device shows a 6-character code (or a QR code) and
the other types it in — after that they're paired.

Songs copy device-to-device. The transfer is encrypted end-to-end, so the
server that routes it can't see your music, and it never stores anything
anyway. If the other device is offline when you add something, it picks up what
it missed the next time it reconnects.

Unpairing a device deletes the songs it received from you, and vice versa.
Songs you added yourself stay. You don't have to pair anything if you don't
want to — it works as a normal local music player too.

The "server" is only a relay: it hands out pairing codes, tracks who's online,
and shuttles encrypted bytes between paired devices. Run it on a VPS, a
Raspberry Pi, or your PC. Point it at a TLS cert if you want `wss://` for
internet use.

## Layout

- `server/` — Node.js signaling server (pairing, presence, relay)
- `app/` — Flutter app (Windows + Android)

## Getting started

Start the server:

```bash
cd server
npm install
npm start        # listens on :8080
```

Run the app:

```bash
cd app
flutter pub get
flutter run -d windows
```

In the app's Settings, point the signaling server URL at wherever the server
is running (`ws://localhost:8080` if it's the same machine) and give the device
a name. Then pair: Devices → Pair a device on one side to generate a code,
enter it on the other side, and you're done.

## Tests

```bash
cd server && node test/smoke.js   # needs the server running on :8080
cd app && flutter test
```

## Notes

- Flutter 3.44.9 / Dart 3.12.
- Windows Developer Mode needs to be on for Flutter's plugin symlinks.
- Android allows plain `ws://` during development.

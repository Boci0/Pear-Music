# Pear Music

The Pear Music client, built with Flutter for Windows and Android (one
codebase). See the [root README](../README.md) for what the app does, how to
run the server, and how pairing works.

## Running

```bash
flutter pub get
flutter run -d windows          # or: flutter run -d <android-device-id>
```

Open the app's Settings and set the signaling server URL and a device name
before pairing.

## Tests

```bash
flutter test
```

# Shadow Network

Shadow Network is an Android-first Flutter capstone app for offline disaster coordination.  
It supports SOS/chat message creation, local SQLite persistence, and Store-Carry-Forward relay over BLE and Wi-Fi Direct when internet connectivity is unavailable.

## Current Capabilities

- Offline SOS and chat messaging with structured payloads and hashing
- Store-Carry-Forward relay with deduplication, TTL expiry, and hop tracking
- Local peer, conversation, and delivery persistence in SQLite (`shadownetwork.db`)
- Offline Panabo map rendering with bundled vector tiles and fonts
- Browser admin dashboard for device registration and trust-bundle export
- Mobile trust-bundle QR/JSON import with approved/unknown/revoked trust enforcement
- Validation session capture with exportable JSON/CSV metrics

## Repository Layout

- `lib/main.dart`: Android/mobile entry point
- `lib/admin_web_main.dart`: browser admin entry point
- `lib/features/`: feature modules (`data`, `domain`, `presentation`)
- `test/`: unit and widget tests
- `docs/`: protocol and security reference documents
- `.github/workflows/android-release.yml`: CI/release workflow

## Prerequisites

- Flutter SDK (project CI uses Flutter `3.41.7`, stable channel)
- Dart SDK compatible with `sdk: ^3.11.5`
- Java 17 (for Android builds)
- Android SDK/toolchain configured for Flutter

## Local Development

From the repository root:

```sh
flutter pub get
flutter analyze
flutter test
```

Run the Android app:

```sh
flutter run -d <android-device-id>
```

Run the browser admin dashboard (fixed origin for local persistence):

```sh
flutter run -d edge -t lib/admin_web_main.dart --web-port 8080
```

Then open `http://localhost:8080`.

Build Android APK:

```sh
flutter build apk
```

## CI and Release Script

The workflow at `.github/workflows/android-release.yml`:

- runs on pushes to `main`/`master` and on manual dispatch
- executes `flutter pub get`, `flutter analyze --no-pub`, and `flutter test --no-pub`
- builds a release APK with `flutter build apk --release`
- publishes a GitHub Release with tag format `v<pubspec version>+<run number>`

## Notes

- `lib/main.dart` attempts Firebase initialization, but startup continues if Firebase is unavailable.
- Keep trust/security behavior aligned with:
  - `docs/SECURITY_TRUST_CONTRACT.md`
  - `docs/PHASE_1_ENCRYPTION.md`
  - `docs/PROTOCOL_COMPATIBILITY.md`

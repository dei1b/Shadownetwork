# Shadow Network

Shadow Network is an Android-first Flutter application for disaster coordination when internet access is unreliable or unavailable. It lets people create and exchange SOS and chat messages, keeps message data on the device, and forwards messages opportunistically between nearby devices using Bluetooth Low Energy (BLE) and Wi-Fi Direct.

The project also includes a browser-based administrator dashboard for device registration and trust-bundle management. The dashboard is a companion tool; the field messaging app is designed around local storage and peer-to-peer communication.

## What the app does

- **Create SOS messages:** send a structured request with a category, message text, time, and available location details.
- **Chat with nearby users:** compose and view conversations using the local messaging store.
- **Carry and forward messages:** queue messages on the device, exchange them with peers, deduplicate received messages, track hop count, and apply time-to-live (TTL) expiry.
- **Use offline maps:** view the bundled Panabo vector map, including its tiles, style, fonts, and sprites, without fetching map tiles from an online service.
- **Protect and verify messages:** support encrypted targeted messages, device signing identities, and trust decisions for approved, unknown, or revoked devices.
- **Review relay status:** see connection and delivery status while the app manages its relay runtime, including Android foreground-service operation.
- **Record field sessions:** collect delivery, discovery, latency, propagation, hop, transport, fallback, and battery telemetry, then copy session summaries as JSON or CSV.
- **Manage device registration:** use the browser admin dashboard to register devices and export trust bundles for mobile import.

Wireless range, delivery, background behavior, battery use, and multi-device relay depend on Android device capabilities and require validation on the target devices. The app includes mock transport and automated tests for development; these do not replace physical-device field trials.

## Project layout

```text
lib/
  app/                       App setup and shell
  core/                      Shared styles, tokens, and widgets
  features/                  Authentication, messaging, trust, maps, validation, admin
  main.dart                  Android/mobile entry point
  admin_web_main.dart        Browser admin entry point
assets/                      App images and offline map data
android/                     Android application and native relay integration
test/                        Flutter unit and widget tests
.github/workflows/           Android build and release automation
```

The offline map tiles, fonts, styles, and sprites under `assets/` are runtime assets and must remain available when building the app.

## Requirements

- Flutter SDK **3.41.7** (stable; the CI workflow uses this version)
- Dart SDK compatible with the version constraint in `pubspec.yaml` (`^3.11.5`)
- Java 17 and Android SDK for Android builds
- An Android device or emulator for running the mobile app

## Get started

From the repository root, install dependencies:

```sh
flutter pub get
```

Run static analysis and the automated test suite:

```sh
flutter analyze
flutter test
```

Run on a connected Android device or emulator:

```sh
flutter devices
flutter run -d <android-device-id>
```

Build a release APK:

```sh
flutter build apk --release
```

The APK is written to `build/app/outputs/flutter-apk/app-release.apk`.

## Browser admin dashboard

Run the administrator dashboard locally in Edge:

```sh
flutter run -d edge -t lib/admin_web_main.dart --web-port 8080
```

Then visit [http://localhost:8080](http://localhost:8080). Use a consistent local origin when returning to the dashboard because browser-local storage is tied to that origin. Admin registry persistence is browser-local; it is not a shared cloud service.

## Android permissions and connectivity

Nearby-device discovery and relay require the relevant Android Bluetooth, Wi-Fi, and location permissions and enabled device radios. Grant the permissions requested by Android and enable the radios needed for the transport being used. SOS creation, local message storage, and viewing bundled map data are available independently of internet access. Firebase initialization is attempted by the mobile entry point, but startup continues if Firebase is unavailable.

## Build and release automation

The GitHub Actions workflow in `.github/workflows/android-release.yml` runs on pushes to `main` or `master` and on manual dispatch. It resolves Flutter dependencies, runs analysis and tests, builds a release APK, and publishes the APK as a GitHub Release. Release tags use the format `v<pubspec version>+<workflow run number>`.

## Repository scope

This repository contains the application source, required platform files, tests, CI configuration, and runtime assets. Keep generated documentation diagrams, reports, local planning files, build output, and credentials out of Git. Do not remove or ignore the offline map and branding assets used by the app.

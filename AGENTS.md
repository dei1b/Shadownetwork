# Repository Guidelines

## Project Structure & Module Organization
The Flutter app lives at the repository root; run project commands there. App code is under `lib/`, with shared app setup in `lib/app`, reusable tokens/widgets in `lib/core`, and feature modules in `lib/features/<feature>/data`, `domain`, and `presentation`. Tests live in `test/`, with fixtures and helpers in `test/support/`. Static assets are in `assets/`, including auth/home images and offline Panabo map fonts, sprites, styles, and vector tiles. Platform-specific code is in `android/`, `ios/`, `linux/`, `macos/`, `web/`, and `windows/`; Android is the capstone delivery target.

## Build, Test, and Development Commands
From the repository root:

```sh
flutter pub get
flutter analyze
flutter test
flutter run
flutter build apk
```

`flutter pub get` installs dependencies, `flutter analyze` applies `flutter_lints`, `flutter test` runs unit/widget tests, `flutter run` starts a local device or emulator build, and `flutter build apk` creates the Android release artifact.

## Coding Style & Naming Conventions
Use Dart defaults: two-space indentation, `lowerCamelCase` for variables and methods, `UpperCamelCase` for classes/enums, and `snake_case.dart` filenames. Keep widgets focused on rendering; put state transitions in Riverpod providers/notifiers and business rules in domain services. Prefer repository interfaces in `domain` and concrete SQLite, transport, or platform implementations in `data`.

## Testing Guidelines
Use `flutter_test`; SQLite-related tests may use `sqflite_common_ffi`. Name tests by behavior, usually `<unit>_test.dart`, such as `scf_service_test.dart` or `sos_message_payload_test.dart`. Add focused tests for payload serialization, deduplication, TTL expiry, hop count changes, database migrations, trust/security logic, and validation metrics. Run `flutter analyze` and `flutter test` before opening a PR.

## Commit & Pull Request Guidelines
Recent commits use short imperative summaries, for example `Implement offline disaster messaging improvements` and `Cache offline Panabo tiles and fix map marker drift`. Keep commits scoped and descriptive; avoid vague messages such as `testing` when possible. PRs should explain the user-facing change, list tests run, link related issues or capstone tasks, and include screenshots or screen recordings for UI changes.

## Architecture & Configuration Notes
Core emergency flows must work offline: SOS creation, SQLite persistence, Store-Carry-Forward relay, peer state, and offline maps cannot depend on internet access. Preserve capstone vocabulary in code and UI: SOS, peers, relay, Store-Carry-Forward, TTL, hop count, message hash, triage, and payload category. Do not commit secrets; review `android/app/google-services.json` and any Firebase or signing configuration before sharing builds.

## Project Skills
Skills are stored in `.agents/skills/<name>/SKILL.md`. Read the relevant skill when its scope matches the request. Read `CURRENT_STATE.md` for the current implementation and verify its claims against code before making changes.

| Skill | Origin | Use |
| --- | --- | --- |
| `shadow-network-relay-architect` | Custom | Implement or review SOS/chat persistence, BLE and Wi-Fi Direct transport, and Store-Carry-Forward routing. |
| `shadow-network-validation-planner` | Custom | Design field trials and interpret exported delivery, discovery, latency, hop, and battery evidence. |
| `flutter-expert` | Jeff Allan / Synergetic Solutions | Develop Flutter widgets, Riverpod state, Android integrations, widget tests, and app performance improvements. |
| `security-threat-model` | OpenAI | When explicitly requested, model threats to peer messaging, device identity, encrypted payloads, trust bundles, and admin registration. |

The provider skills were downloaded unchanged from their published repositories:

- [Flutter expert source](https://github.com/Jeffallan/claude-skills/tree/1be15d8064f88fc25216442406d40add8fd23b53/skills/flutter-expert), revision `1be15d8064f88fc25216442406d40add8fd23b53`. Its repository MIT license is included in the local skill folder.
- [Security threat model source](https://github.com/openai/skills/tree/49f948faa9258a0c61caceaf225e179651397431/skills/.curated/security-threat-model), revision `49f948faa9258a0c61caceaf225e179651397431`.

Keep the provider licenses and supporting files with their skills. Put project-specific instructions in this guide or the custom skills rather than changing the provider copies.

Apply Flutter guidance within this existing app: retain Riverpod, the current navigation and module structure, and Android-first delivery. Choose APIs compatible with `pubspec.yaml`; do not scaffold a replacement project, introduce Bloc/GoRouter, or perform broad dependency upgrades unless the requested change requires them.

# Shadow Network Current App State

Updated: 2026-08-15

Repository: `C:\Users\Dave\Desktop\Shadownetwork\shadownetwork`

## Purpose of This Document

This file is the current technical snapshot of the Shadow Network capstone project. It records what is verifiably implemented in the repository, what is only partially implemented, and what remains future work. Future changes should update this file whenever a database version, payload schema, transport behavior, trust rule, major screen, or validation capability changes.

## Executive Summary

Shadow Network is an Android-first Flutter application for offline disaster messaging. It allows devices to create SOS and chat messages, save them locally, discover nearby Shadow Network devices, and relay queued payloads through Bluetooth Low Energy (BLE) or Wi-Fi Direct using Store-Carry-Forward (SCF).

The project is beyond a static UI prototype. The repository currently includes:

- SQLite-backed SOS, chat, peer, conversation, and SCF persistence.
- Structured, hashed, and versioned SOS and chat payloads.
- SCF deduplication, TTL expiry, hop counting, retry state, and per-peer delivery tracking.
- Android BLE discovery, app-peer identity exchange, BLE payload transfer, Wi-Fi Direct discovery, and TCP transfer.
- A foreground-service notification and in-process background relay runtime.
- Same-sender Jaccard and normalized Levenshtein spam detection.
- Non-spam SOS map markers using bundled Panabo map assets.
- A browser-based admin registry with pending, approved, and revoked device states.
- Trust-bundle export on the admin website and QR/JSON import on Android.
- Public-only phone registration QR display and PC-camera form auto-fill.
- Automatic mobile role resolution from the phone identity and imported trust bundle.
- A responder-focused mobile dashboard for approved responder devices.
- Recipient selection for targeted SOS messages.
- Standard authenticated encryption for targeted SOS and chat bodies so relay-only devices cannot display or modify their content undetected.
- Ed25519-signed Version 2 trust bundles with administrator-key pinning, expiry, monotonic versions, and rollback rejection.
- Persisted approved, unknown, and revoked device trust states enforced across receiving, feeds, maps, recipient selection, and SCF relay eligibility.
- Persisted responder validation sessions with real discovery, connection, relay, delivery, transport, runtime, latency, hop, and battery events.
- Live validation summaries plus JSON and CSV export for manual backup and adviser review.

The project should still be treated as a capstone prototype rather than a production emergency system. Its largest remaining risks are sender authentication, secure multi-admin persistence, durable background execution, battery-aware scanning, mobile-to-admin synchronization, and real-device field validation.

## Main Entry Points

### Android Mobile App

- Entry point: `lib/main.dart`
- App widget: `lib/app/app.dart`
- Main shell: `lib/app/presentation/pages/app_shell_page.dart`
- Main interface: `lib/features/messaging/presentation/pages/home_page.dart`

Run on an Android device:

```powershell
flutter run -d <android-device-id>
```

### Browser Admin App

- Entry point: `lib/admin_web_main.dart`
- Dashboard: `lib/features/admin/presentation/pages/browser_admin_dashboard_page.dart`

Use a fixed port because browser-local persistence is tied to the website origin:

```powershell
flutter run -d edge -t lib\admin_web_main.dart --web-port 8080
```

Then open `http://localhost:8080`.

## Current Technology Stack

| Area | Current implementation |
|---|---|
| Application framework | Flutter and Dart |
| State management | Riverpod |
| Mobile target | Android-first |
| Authentication code | Firebase Auth and Google Sign-In |
| Local relational storage | SQLite through `sqflite` |
| Test database | `sqflite_common_ffi` |
| Admin/trust local storage | `shared_preferences` |
| Location | `geolocator` |
| Map | `maplibre_gl` with bundled Panabo vector assets |
| Hashing | SHA-256 through `crypto` |
| Android integration | Kotlin through a Flutter `MethodChannel` |
| Nearby discovery | BLE and Wi-Fi Direct DNS-SD |
| Payload transfer | BLE GATT chunks and Wi-Fi Direct TCP sockets |
| Background visibility | Android connected-device foreground service |
| QR generation/import | `qr_flutter` and `mobile_scanner` |

## Application Startup and Authentication

- `main.dart` attempts Firebase initialization and starts the app inside `ProviderScope`.
- `DisasterCommApp` uses the shared Shadow Network light theme.
- Login and signup routes and a Firebase authentication repository exist.
- Google Sign-In support is included in the project dependencies.
- The current `home` route opens `AppShellPage` directly; authentication is not currently enforced as a gate before emergency messaging.
- `AppShellPage` resolves the local device access profile before displaying the main interface.
- Responder access requires an approved local device ID, matching X25519 public key and key version, and the `responder` role.
- Revocation takes priority over approval. Unregistered, key-mismatched, and revoked devices cannot enter the responder interface.
- Approved responders are routed automatically to a responder-focused dashboard; there is no manual role-switch setting.
- The mobile app does not contain an admin dashboard. Administration is separated into the browser entry point.

## Mobile Role-Based Interface

The mobile application uses one Android APK for civilians and responders. The interface is selected locally from the imported trust bundle:

- Approved `responder` devices receive responder navigation for Dashboard, Alerts, SOS Map, and Network.
- The responder dashboard prioritizes legitimate SOS alerts, the SOS triage map, responder chats, connection diagnostics, location, and device trust status.
- Approved civilian, relay, and admin records remain in the standard civilian interface.
- Unregistered devices remain usable for civilian emergency messaging but display registration guidance.
- Key-mismatched and revoked devices remain outside responder mode and display a blocking access warning.
- Expired signed bundles display a specific refresh warning and disable trusted-role access without disabling civilian broadcast SOS.
- Importing or clearing a trust bundle invalidates the access profile immediately, so the shell updates without an app restart.

Current boundary: the first valid signed bundle pins its administrator Ed25519 public key on the phone using trust on first use (TOFU). The administrator key is not certified by an external PKI, and clearing the active bundle intentionally does not clear that pinned administrator identity.

## Local Database

Database file: `shadownetwork.db`

Current database version: `8`

### Tables

- `peer_types`
- `peers`
- `categories`
- `sos_messages`
- `scf_messages`
- `scf_peer_statuses`
- `conversations`
- `chat_messages`
- `trusted_devices`
- `trust_bundle_metadata`
- `validation_sessions`
- `message_events`
- `discovery_attempts`
- `battery_samples`
- `metric_sync_batches`

### Implemented database behavior

- Foreign keys are enabled with `PRAGMA foreign_keys = ON`.
- Category and peer-type lookup rows are seeded automatically.
- Database migrations are defined from version 1 through version 8.
- SOS and chat messages persist routing, moderation, encryption, and sender-trust snapshots.
- SCF payloads are stored separately from user-facing SOS and chat records.
- SCF payloads persist origin trust state so revoked-origin envelopes can be retained without being offered for relay.
- Per-peer delivery attempts, status, timestamps, and last errors are stored in `scf_peer_statuses`.
- Conversations use a unique local-peer and remote-peer pair.
- Verified trust-bundle records and metadata survive app restart in SQLite.
- Validation sessions, telemetry events, battery samples, and export/sync records survive app restart in SQLite.

### Version 6 additions

- `sos_messages.recipient_peer_id`
- `sos_messages.is_encrypted`

### Version 7 additions

- `trusted_devices` and `trust_bundle_metadata`
- `sos_messages.trust_status`, `trust_role`, and `trust_owner_name`
- `chat_messages.trust_status`, `trust_role`, and `trust_owner_name`
- `scf_messages.origin_trust_status`

### Version 8 additions

- `validation_sessions` for named, role-aware test runs and their lifecycle.
- `message_events` for queue, connection, relay, delivery, rejection, transport, and runtime events.
- `discovery_attempts` for timed BLE/Wi-Fi Direct discovery outcomes.
- `battery_samples` for actual Android battery level, charging state, and runtime mode.
- `metric_sync_batches` for manual exports now and responder-to-PC synchronization in Phase 4.

## SOS Payload Contract

Current SOS payload schema version: `4`

Default TTL: `24 hours`

The current payload contains:

- `schema_version`
- `message_hash`
- `message_id`
- `payload_text`
- `category`
- `location.latitude`
- `location.longitude`
- `location.accuracy_meters`
- `routing.hop_count`
- `routing.ttl`
- `timestamp.created_at`
- `sender`
- optional `recipient`
- `security`

Implemented behavior:

- SHA-256 produces a deterministic message hash.
- Mutable relay hop count is normalized to zero when calculating the hash.
- Relay rewriting changes the hop count without changing the message hash.
- Legacy SOS schema versions 1, 2, and 3 remain readable.
- Broadcast SOS messages retain plaintext in `payload_text` and set `security.encrypted` to false.
- Targeted SOS messages set `payload_text` to null and place the key ID/version, ephemeral X25519 public key, random nonce, ciphertext, authentication tag, algorithm, and protocol version under `security`.
- Immutable message metadata is authenticated as AES-GCM additional authenticated data; mutable hop count remains relay-editable.
- A non-recipient device keeps and relays a targeted envelope but does not save it as a visible SOS message.
- The intended recipient decrypts and saves the targeted SOS, then consumes its delivered SCF payload.

Relevant files:

- `lib/features/messaging/data/models/sos_message_payload.dart`
- `lib/features/messaging/data/models/secure_sos_message_payload.dart`
- `lib/features/messaging/data/models/sos_payload_crypto.dart`
- `lib/features/security/data/services/message_encryption_service.dart`
- `lib/features/messaging/domain/entities/sos_message.dart`

## Chat Payload Contract

Current chat payload schema version: `2`

Implemented behavior:

- Chat messages are targeted to a recipient device.
- New chat payloads contain no plaintext body and use the same authenticated X25519/HKDF/AES-GCM envelope as targeted SOS.
- Chat payloads include sender, recipient, conversation, routing, timestamp, and optional related-SOS metadata.
- SHA-256 message hashing ignores mutable hop count.
- A relay-only device stores and carries a chat envelope without displaying it.
- The intended recipient opens or updates the conversation, applies spam classification, saves the message, increments unread state, and consumes the delivered SCF payload.

Legacy chat schema version 1 remains readable for compatibility; production outgoing chat uses encrypted schema version 2.

## Store-Carry-Forward Relay

Implemented SCF behavior includes:

- Storing SOS and chat payloads as envelopes.
- Rejecting envelopes whose payload hash does not match the envelope hash.
- Deduplicating active messages by deterministic `message_hash`.
- Allowing a previously expired hash to be stored again.
- Pruning expired envelopes using `expires_at`.
- Incrementing hop count exactly once when preparing a payload for a peer.
- Limiting outbound batches, with a default per-peer limit of 50.
- Recording offered, sent, failed, and delivered-related peer state.
- Retrying payloads whose peer delivery status is pending or failed.
- Retaining non-target envelopes for later relay.
- Removing chat and targeted SOS envelopes after successful local delivery to the intended recipient.
- Resolving an incoming envelope's claimed sender ID against the current persisted trust state before relay preparation.
- Retaining revoked-origin envelopes for audit while excluding them from automatic relay.
- Continuing to relay unknown-origin envelopes because unregistered emergency users must remain reachable.

Relevant files:

- `lib/features/messaging/data/services/scf_service.dart`
- `lib/features/messaging/data/services/scf_relay_service.dart`
- `lib/features/messaging/domain/entities/scf_envelope.dart`
- `lib/features/messaging/domain/entities/scf_peer_delivery.dart`

## Relay Runtime and ECB-Style Trigger

The Riverpod relay runtime currently:

- Starts automatically after `AppShellPage` is displayed.
- Obtains the local peer identity.
- Discovers and persists nearby peer snapshots.
- Receives and stores new SCF envelopes.
- Converts only locally visible payloads into SOS or chat records.
- Applies spam detection to outgoing and incoming visible messages.
- Attempts to relay queued envelopes to discovered peers.
- Tracks running, syncing, permissions, discovered peers, connected peers, last update, receive count, relay count, and last error.
- Listens for native `onRelayEvent` callbacks and schedules an immediate synchronization after a short debounce.

Current timing:

- Periodic synchronization: every `4 seconds`.
- Native-event debounce: `350 milliseconds`.

The term ECB-style describes immediate local processing after a nearby Shadow Network payload event. This is not Android's cellular Emergency Cell Broadcast API and does not bypass Android radio, permission, or background-execution rules.

## Android BLE and Wi-Fi Direct Transport

The Android bridge currently provides:

- Runtime permission requests.
- Local peer identity and transport status.
- Start and stop operations.
- Peer discovery and manual peer connection.
- Envelope send and receive operations.
- Native relay-event callbacks to Flutter.

### BLE behavior

- Advertises a Shadow Network BLE service UUID.
- Scans only for that service UUID.
- Reads application identity over a GATT characteristic before exposing a peer to Flutter.
- Rejects incompatible app IDs and protocol versions.
- Uses resolved peer IDs and device names instead of intentionally keeping the generic `BLE Peer` identity.
- Transfers envelopes through chunked BLE GATT writes.

### Wi-Fi Direct behavior

- Advertises and discovers Shadow Network services through Wi-Fi Direct DNS-SD.
- Includes app ID, protocol version, peer ID, peer name, and port in the service record.
- Establishes Wi-Fi Direct groups and TCP socket connections.
- Prefers Wi-Fi Direct when a peer has been discovered through that transport.
- Falls back to BLE when Wi-Fi Direct connection or transfer fails and a BLE address is available.

### Local device identity

- The mobile device ID normally uses `local-device-` plus the final eight characters of Android `ANDROID_ID`.
- The device ID is exchanged through BLE identity and Wi-Fi Direct service records.
- The ID and X25519 public key are displayed on the Trust Bundle screen and can be shown together as a registration QR for the PC admin dashboard.
- It is an application peer identifier, not the phone's Bluetooth MAC address.
- Android ID behavior can change after events such as a factory reset or signing/user changes; it should not be treated as a permanent hardware serial number.

## Permissions and Background Operation

The Android manifest declares permissions for:

- Camera access for QR scanning.
- Internet and network state.
- Wi-Fi state and Wi-Fi Direct changes.
- Foreground connected-device service.
- Notifications.
- Fine and coarse location.
- Legacy Bluetooth permissions through Android 11.
- Bluetooth scan, advertise, and connect on newer Android versions.
- Nearby Wi-Fi devices on Android 13 and later.

The foreground service displays the ongoing notification `Shadow Network relay active` with the text `Listening for nearby peers and queued messages.`

Current boundary: background relaying is designed to continue while the Flutter process remains alive and the UI is paused. The foreground service itself mainly maintains Android foreground-service status; it does not independently rebuild the full Flutter relay runtime after process death, force-stop, reboot, or aggressive manufacturer battery management. Durable recovery still requires additional native scheduling/service work and real-device validation.

## Offline Map and Location

- The mobile app obtains position updates through `geolocator`.
- MapLibre receives a local style URL from an in-app loopback tile server.
- Panabo vector tiles, fonts, sprites, and style assets are bundled for selected zoom levels.
- Missing assets can be fetched from OpenFreeMap and cached when internet access is available.
- Location follow behavior and SOS category filters are implemented.
- Only non-spam, non-revoked SOS messages with visible, valid coordinates are eligible for map markers.

Current boundary: the map is offline only where the required assets are already bundled or cached. Coverage is Panabo-focused and is not yet a complete offline package for all of Tagum City or other deployment areas.

## Anti-Spam Moderation

Current moderation statuses:

- `normal`
- `spam`

Current detection rules:

- Compare a candidate only with recent messages from the same sender peer ID.
- Ignore similar messages from other senders.
- Use a 10-minute comparison window.
- Normalize message text before comparison.
- Calculate Jaccard word similarity.
- Calculate normalized Levenshtein similarity.
- Classify as spam when Jaccard similarity is at least `0.80` or Levenshtein similarity is at least `0.85`.

UI behavior:

- All Messages excludes spam-classified records.
- The Spam filter displays only spam-classified records.
- Spam records remain stored locally.
- Spam SOS messages are excluded from map markers.

Spam classification is local and heuristic. It does not prove that an emergency report is false, and the app does not hard-delete suspicious messages.

## Mobile Messaging Interface

Implemented mobile areas include:

- Main SOS and message dashboard.
- SOS composer with category, message, location, and receiver selection.
- Broadcast SOS option.
- Approved-device receiver dropdown showing owner, role, and shortened device ID.
- Targeted SOS encryption notice.
- Message filters including Spam and Quarantine.
- SOS map and category filtering.
- Nearby peer cards and connection actions.
- Conversation list and chat screen.
- Connection and relay status presentation.
- Trust Bundle screen with local device ID, encryption public key, PC registration QR, signature state, version, validity, issuer key, and import time.
- Signed trust-bundle QR scanning, clipboard import, manual JSON import, first-administrator confirmation, rollback protection, summary, and clearing.
- Responder-only Validation Test screen for starting, monitoring, exporting, and completing persisted field-test sessions.
- App update-check service and provider.

## Browser Admin and Device Trust

The separate Flutter web admin currently supports:

- Registering a device ID, encryption public key, owner name, and role.
- PC-camera scanning of a phone registration QR to auto-fill the exact Device ID and public-key fields.
- Roles: civilian, responder, relay, and admin.
- Initial pending status for new registrations.
- Approving or revoking registered devices.
- Editing a registered device owner name/username and role without changing its device ID or encryption key.
- Permanently deleting pending, approved, or revoked registry entries after confirmation.
- Browser-local persistence through `shared_preferences`.
- Removal of old fake sample devices from persisted registry data.
- Exporting approved and revoked devices as a canonical Ed25519-signed Version 2 JSON trust bundle.
- Copying the trust bundle or displaying it as a QR code.
- Empty validation-metric placeholders rather than fabricated values.

The Android app verifies the signed bundle before replacing local trust state. Bundle versions increase monotonically, older versions and altered same-version bundles are rejected, failed imports preserve the last valid bundle, and a different administrator key is rejected after first-use pinning. Approved devices are normal recipients and receive an Approved/Verified trust indicator; unknown senders remain visible as Unverified; revoked senders are retained in Quarantine but excluded from normal feeds, maps, and automatic relay.

### Admin limitations

- The admin registry exists only in the current browser origin's local storage.
- Changing browser, hostname, or port can expose a different local registry.
- There is no backend database, admin account authentication, multi-admin synchronization, or audit log.
- The website does not automatically receive SOS messages and does not act as a BLE/Wi-Fi Direct rescuer node.
- There is no automatic mobile-rescuer-to-PC synchronization.
- Device public-key entry is implemented in the browser registration form, and approved keys are exported in trust bundles.
- Manual Device ID/public-key entry remains available when the PC has no camera.
- The browser signing key is stored in browser-local `shared_preferences`, not an operating-system hardware keystore or authenticated backend.
- Every copied or displayed bundle is a new signed version with a 30-day validity period; phones must import a newer bundle before expiry.
- The first imported administrator key is trusted through an explicit TOFU confirmation, not an external certificate authority.
- Permanently deleting a revoked record removes it from future trust bundles; revocation remains the safer choice for compromised or previously deployed devices.

## Security Status

### Implemented

- Long-term X25519 device identities are generated on-device and private keys are stored with platform secure storage.
- Each targeted message uses a fresh ephemeral X25519 key agreement, HKDF-SHA-256 content-key derivation, and AES-256-GCM authenticated encryption.
- Targeted SOS and chat bodies are absent from relay-visible plaintext fields.
- Immutable identity, recipient, location/category, timestamp, TTL, and conversation metadata is authenticated.
- Non-recipient devices relay opaque envelopes without displaying message content.
- Modified ciphertext, tags, nonces, keys, or authenticated metadata is rejected.
- Missing recipient public keys prevent sending instead of causing plaintext fallback.
- Approved trust-bundle devices carry public-key and key-version metadata.
- Trust bundles use canonical JSON and Ed25519 signatures, include issuer/signing-key IDs and expiry, and reject tampering, rollback, or issuer replacement.
- Version 7 persists trusted-device state and a trust snapshot on received SOS/chat and SCF records.
- Unknown-origin emergency messages remain visible with an Unverified indicator.
- Revoked-origin messages are quarantined and excluded from normal feeds, maps, and automatic relay.

### Important limitations

- SOS schema 3 and `sn-sha256-stream-v1` remain readable only for migration compatibility and must not be used for new outgoing messages.
- Broadcast SOS payload bodies remain plaintext by design.
- Payload hashes are not digital signatures and do not authenticate the sender.
- Approved/Verified labels indicate a match between the payload's claimed device ID and the signed administrative list; sender message signatures are still required to prevent device-ID spoofing cryptographically.
- The PC administrator signing key and registry are browser-local and do not yet have admin login, audit logging, backup, or secure multi-PC synchronization.
- Clearing application data rotates the private key; the replacement public key must be re-registered and redistributed before older targeted envelopes can be decrypted.

## Validation Metrics Status

Version 8 implements persisted validation sessions on responder devices. From the responder dashboard, `VALIDATION TEST` opens the session screen where the tester can provide a session name, environment, and notes, then start or stop the run. An active session resumes after app/database restart and shows its elapsed time, telemetry count, device role, and export state.

The runtime records real events only while a session is active:

- SOS and chat queued events.
- Peer discovery attempts, discovered peers, scan duration, result, and transport.
- Connection attempts, successes, failures, and elapsed time.
- Envelope offered, sent, received, relayed, delivered, expired, and rejected events.
- Actual BLE, Wi-Fi Direct, or mock-test transport and whether fallback was used.
- Foreground/background runtime-mode changes.
- Android battery percentage and charging state at session start, during the run, lifecycle changes, and completion.

Calculated values use the persisted evidence rather than placeholders:

- Delivery success rate uses successful local send attempts divided by successful plus failed send attempts. A receiver-only session uses uniquely delivered envelopes divided by uniquely received envelopes.
- Peer-discovery success rate uses successful scans divided by completed discovery attempts.
- Node-to-node latency uses the measured duration of the actual transport send operation.
- End-to-end propagation uses local delivery time minus the original payload creation or queue timestamp when that evidence is available.
- Hop-count distribution uses the hop value recorded on received or delivered envelopes.
- Transport usage counts BLE and Wi-Fi Direct sends, and fallback rate uses recorded fallback events.
- Battery impact is reported only from at least two real, non-charging battery samples; otherwise the UI states that more evidence is needed.

Completed and active sessions can be exported as schema-versioned JSON or summary CSV through the system clipboard. JSON can be imported by the validation repository with duplicate event IDs ignored, enabling safe manual backup and later Phase 4 synchronization work.

Current boundary: metrics remain local to each phone. The PC browser dashboard intentionally displays `No data` because automatic responder-to-PC synchronization, multi-device aggregation, and historical admin charts belong to Phase 4. A local sender success rate is not yet a cryptographic end-to-end acknowledgment from the destination device.

## Automated Tests

Current test files:

- `test/admin_device_registry_store_test.dart`
- `test/app_update_check_test.dart`
- `test/chat_message_payload_test.dart`
- `test/chat_repository_test.dart`
- `test/local_messaging_database_test.dart`
- `test/message_feed_filter_test.dart`
- `test/messaging_repositories_test.dart`
- `test/mock_scf_transport_test.dart`
- `test/scf_service_test.dart`
- `test/sos_message_payload_test.dart`
- `test/spam_detection_service_test.dart`
- `test/trust_bundle_store_test.dart`
- `test/validation_metrics_test.dart`

Covered behavior includes:

- Database schema creation and lookup seeding.
- Version 6 targeted-SOS columns.
- Repository persistence.
- SOS and chat payload hashing and parsing.
- Targeted SOS encryption, intended-recipient decoding, non-recipient rejection, and relay without plaintext.
- SCF deduplication, expiry, hop increment, retry, and peer status.
- Mock peer transport and returned-payload deduplication.
- Same-sender spam detection and cross-sender isolation.
- Jaccard reordered-word and Levenshtein variation detection.
- All/Spam feed filtering and non-spam map markers.
- Admin registry persistence and fake-sample removal.
- Trust-bundle export, import, validation, persistence, and clearing.
- Version 8 migration, persisted active-session recovery, event ownership and duplicate handling.
- Delivery, discovery, latency, propagation, hop, transport, fallback, and battery calculations.
- Validation JSON/CSV export and duplicate-safe JSON import.
- SCF validation instrumentation through the mock transport.

Current automated-test gaps include native Android BLE/Wi-Fi Direct integration, process-death background recovery, QR camera UI, admin page widget behavior, real-device permissions, measured battery impact, range, latency, three-device multi-hop delivery, and mobile-to-PC synchronization.

## Capstone Diagram and Documentation Artifacts

Current repository artifacts include:

- `capstone_erd_implemented_crowfoot.png` and `.svg`
- `capstone_erd_panel.png` and `.svg`
- `capstone_erd_pure_text.txt`
- `capstone_erd_schema.json`
- `capstone_erd_updated.png` and `.svg`
- `shadow_network_sos_json_schema_diagram.png` and `.svg`
- `shadow_network_context_flow_diagram.png` and `.svg`
- `shadow_network_dfd_level_1.png` and `.svg`
- `shadow_network_use_case_diagram_enhanced.png` and `.svg`
- `shadow_network_use_case_diagram_updated.png` and `.svg`
- `shadow_network_conceptual_framework.png`

The updated use case diagram contains one `<<include>>` relationship: Broadcast SOS includes Capture GPS Location.

## Current Known Risks

1. The fixed four-second relay loop and low-latency BLE scan mode can consume significant battery.
2. Background operation is not guaranteed after process death, force-stop, reboot, or manufacturer-specific battery restrictions.
3. Encryption protects confidentiality and integrity, but messages do not yet carry sender signatures.
4. Admin registration and signing keys remain browser-local without authenticated backend persistence or audit logs.
5. Trust classification relies on a claimed sender device ID because per-message sender signatures are not yet implemented.
6. Wi-Fi Direct behavior can require Android system interaction and varies by device and OS version.
7. Real BLE/Wi-Fi Direct reliability, range, latency, and fallback behavior require multi-device field tests.
8. Validation sessions remain phone-local and require manual export; there is no cross-device aggregation or automatic admin synchronization.
9. Offline map coverage is geographically limited.
10. Firebase authentication exists, but the current emergency app shell is not auth-gated and offline identity is separate from Firebase identity.
11. The project `README.md` still contains the default Flutter description.

## Recommended Next Priorities

The phased implementation roadmap for these priorities is maintained in `IMPLEMENTATION_PLAN.md`.

1. Add sender signatures and define trusted key-rotation/retirement handling for historical messages.
2. Add a secure admin backend or controlled local synchronization service with authentication, audit logs, signing-key backup, and stable persistence.
3. Implement authenticated mobile-rescuer-to-admin metric synchronization and cross-device session aggregation.
4. Add adaptive, battery-aware scanning and a durable Android background recovery strategy.
5. Perform structured tests with at least sender, relay, and rescuer Android devices across indoor and outdoor distances.
6. Run persisted validation sessions and record delivery rate, discovery time, node latency, end-to-end propagation, hop count, transport fallback, and battery impact for each trial.
7. Expand and verify offline map coverage for the final deployment area.
8. Update the project README with setup, run, permission, admin, and field-testing instructions.

## Adviser Summary

Shadow Network currently provides a working capstone foundation for offline, device-to-device disaster messaging: local relational persistence, structured SOS and chat payloads, Store-Carry-Forward routing, deterministic message hashing, TTL and hop-count processing, same-sender spam detection, offline map support, Android BLE/Wi-Fi Direct transport code, background foreground-service visibility, X25519/HKDF/AES-GCM encrypted targeted messaging, secure on-device private-key storage, Ed25519-signed and versioned trust bundles, persisted device trust, revoked-message quarantine, and Version 8 responder validation sessions backed by real telemetry and exportable metrics. The next stage should focus on sender authentication, reliable background execution, battery optimization, secure admin persistence, authenticated mobile-to-admin synchronization, and controlled three-device field testing.

## Verification Record

Verified on 2026-08-15:

- `flutter analyze`: passed with no issues found.
- `flutter test`: passed all 82 tests, including registration QR, Phase 0 compatibility, Phase 1 encryption, signed-bundle tamper/rollback/issuer checks, Version 8 migration, persisted trust state, quarantine, revoked relay policy, validation calculations, session recovery, and export/import.
- `flutter build apk --debug --no-pub`: produced `build/app/outputs/flutter-apk/app-debug.apk`.
- `flutter build web --no-pub -t lib/admin_web_main.dart`: produced the browser admin build in `build/web`.

A physical-device Phase 3 field session was not part of this automated verification. Passing tests and application builds do not replace BLE, Wi-Fi Direct, background, range, battery, and three-device multi-hop field validation.

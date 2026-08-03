# Shadow Network Current App State

Updated: 2026-07-20

## Project Summary

Shadow Network is an Android-first Flutter capstone app for offline disaster communication. Its goal is to let nearby phones exchange SOS and chat messages when normal infrastructure is unavailable, using local persistence, peer discovery, and Store-Carry-Forward relay.

The app is no longer only a UI prototype. The current codebase includes SQLite-backed local storage, structured SOS/chat payloads, message hashing, spam moderation, offline map support, Android BLE/Wi-Fi Direct transport code, and a foreground relay service.

## Current Technology Stack

| Area | Current Implementation |
|---|---|
| App framework | Flutter |
| State management | Riverpod |
| Authentication | Firebase Auth and Google Sign-In |
| Local database | SQLite through `sqflite` |
| Test database | `sqflite_common_ffi` |
| Location | `geolocator` |
| Map | `maplibre_gl` with Panabo offline vector map assets |
| Message hashing | SHA-256 through `crypto` |
| Android transport | Kotlin platform bridge through Flutter `MethodChannel` |
| Background relay | Android foreground service |

## Implemented Core Features

### 1. App Shell and Startup

- The app starts from `lib/main.dart`.
- Firebase initialization is attempted on startup.
- Riverpod `ProviderScope` wraps the app.
- `DisasterCommApp` defines routes for login, signup, and the main app shell.
- `AppShellPage` starts the relay runtime automatically after the UI loads.
- The relay is kept alive when the UI is paused or backgrounded; it only stops when the app is detached.

Relevant files:

- `lib/main.dart`
- `lib/app/app.dart`
- `lib/app/presentation/pages/app_shell_page.dart`

### 2. Authentication

- Firebase-backed authentication repository exists.
- Login and signup pages are implemented.
- Google Sign-In dependency is included.
- Auth UI has reusable widgets and styling.

Relevant files:

- `lib/features/auth/data/repositories/firebase_auth_repository.dart`
- `lib/features/auth/presentation/pages/login_page.dart`
- `lib/features/auth/presentation/pages/signup_page.dart`

### 3. Local SQLite Persistence

The local database is implemented as `shadownetwork.db`.

Current database version: `5`

Current tables:

- `peer_types`
- `peers`
- `categories`
- `sos_messages`
- `scf_messages`
- `scf_peer_statuses`
- `conversations`
- `chat_messages`

Important implemented database behavior:

- Foreign keys are enabled with `PRAGMA foreign_keys = ON`.
- Categories and peer types are seeded automatically.
- SOS and chat messages persist message hashes, hop count, TTL, moderation status, moderation reason, and moderation score.
- Store-Carry-Forward envelopes are persisted separately from user-facing messages.
- Per-peer delivery state is tracked in `scf_peer_statuses`.

Relevant file:

- `lib/features/messaging/data/datasources/local_messaging_database.dart`

### 4. SOS Message Payloads

SOS payload serialization is implemented.

Current SOS payload schema version: `2`

The SOS payload contains:

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
- `sender.peer_id`
- `sender.peer_name`
- `sender.peer_type`

Important behavior:

- The message hash is deterministic.
- The hash ignores mutable relay hop count by normalizing `hop_count` to `0` for hashing.
- Legacy schema version `1` payloads can still be parsed.
- Default TTL is `24 hours`.

Relevant file:

- `lib/features/messaging/data/models/sos_message_payload.dart`

### 5. Chat Message Payloads

Chat payload serialization is implemented.

Current chat payload schema version: `1`

The chat payload contains:

- `schema_version`
- `payload_type`
- `message_hash`
- `message_id`
- `conversation_id`
- `body`
- `related_sos_message_hash`
- `routing.hop_count`
- `routing.ttl`
- `timestamp.created_at`
- `sender`
- `recipient`

Important behavior:

- Chat messages are recipient-targeted.
- Chat payload hashes also ignore mutable relay hop count.
- Chat messages can be linked to an SOS message through `related_sos_message_hash`.

Relevant file:

- `lib/features/messaging/data/models/chat_message_payload.dart`

### 6. Store-Carry-Forward Relay

Store-Carry-Forward logic is implemented in the data/service layer.

Implemented behavior:

- Stores SOS and chat payloads as relay envelopes.
- Deduplicates active payloads by deterministic `message_hash`.
- Expires payloads using `expires_at`.
- Prunes expired payloads before preparing outbound relay.
- Increments hop count before relaying to another peer.
- Updates per-peer status as offered, sent, failed, or delivered.
- Retries failed peer delivery attempts.
- Removes delivered chat payloads from the SCF queue after successful local delivery.

Current default relay TTL: `24 hours`

Relevant files:

- `lib/features/messaging/data/services/scf_service.dart`
- `lib/features/messaging/data/services/scf_relay_service.dart`
- `lib/features/messaging/domain/entities/scf_envelope.dart`
- `lib/features/messaging/domain/entities/scf_peer_status.dart`

### 7. Relay Runtime and ECB-Style Processing

The relay runtime is implemented with Riverpod.

Implemented behavior:

- Starts relay runtime automatically.
- Discovers peers.
- Persists discovered peer snapshots.
- Ingests incoming relay envelopes.
- Saves incoming SOS/chat messages locally.
- Applies spam moderation to incoming and outgoing messages.
- Relays queued envelopes to discovered peers.
- Tracks runtime state: running, syncing, permissions, discovered peers, connected peers, last update, last received count, last relayed count, and last error.
- Responds to native relay events using an ECB-style immediate sync trigger.

Current timing:

- Periodic relay sync interval: `4 seconds`
- ECB debounce delay: `350 milliseconds`

Note: the current `4 seconds` interval is useful for testing and demos, but it is aggressive for real battery use. A production/capstone field mode should use duty-cycled adaptive scanning, such as every 2-5 minutes in idle background mode and faster scanning only during active emergency windows.

Relevant file:

- `lib/features/messaging/presentation/providers/relay_runtime_provider.dart`

### 8. Android BLE and Wi-Fi Direct Transport

Android transport is implemented through a Kotlin bridge.

Implemented behavior:

- Flutter communicates with native Android through `MethodChannel`.
- The native bridge exposes:
  - `ensurePermissions`
  - `getLocalPeer`
  - `getTransportStatus`
  - `start`
  - `stop`
  - `discoverPeers`
  - `connectPeer`
  - `sendEnvelope`
  - `receiveEnvelopes`
- BLE advertising and scanning are implemented.
- BLE identity resolution is implemented.
- BLE payload transfer is implemented with chunking.
- Wi-Fi Direct discovery and service advertisement are implemented.
- Wi-Fi Direct is preferred for peers discovered through Wi-Fi Direct.
- BLE is used as fallback where needed.
- Incoming native envelope events notify Flutter through `onRelayEvent`.

Relevant files:

- `lib/features/messaging/data/services/android_scf_transport.dart`
- `android/app/src/main/kotlin/com/example/shadownetwork/AndroidTransportBridge.kt`
- `android/app/src/main/kotlin/com/example/shadownetwork/MainActivity.kt`

### 9. Android Permissions and Background Service

Android permissions are declared for:

- Internet and network state
- Wi-Fi state and Wi-Fi Direct support
- Foreground service
- Foreground connected-device service
- Notifications
- Fine and coarse location
- Bluetooth classic permissions for older Android versions
- Bluetooth scan, advertise, and connect for newer Android versions
- Nearby Wi-Fi devices

Android features are declared for:

- Bluetooth LE
- Wi-Fi Direct

Background relay is supported by a foreground service with an ongoing notification:

- Notification title: `Shadow Network relay active`
- Notification text: `Listening for nearby peers and queued messages.`

Relevant files:

- `android/app/src/main/AndroidManifest.xml`
- `android/app/src/main/kotlin/com/example/shadownetwork/RelayForegroundService.kt`

### 10. Offline Map and Location

The home page uses MapLibre and a local tile server for Panabo map assets.

Implemented behavior:

- Offline map style is served from bundled assets.
- Bundled vector tiles, sprites, and fonts are available for Panabo.
- If an asset is missing, the tile server can attempt an online fetch and cache the result.
- Current location is obtained with `geolocator`.
- Location follow mode is implemented.
- SOS markers are filtered so only non-spam messages with valid coordinates appear on the map.
- Map category filters are available.

Relevant files:

- `lib/features/messaging/presentation/pages/home_page.dart`
- `lib/features/messaging/data/services/offline_panabo_tile_server.dart`
- `lib/features/messaging/presentation/utils/message_feed_filter.dart`
- `assets/map_styles/panabo_offline.json`
- `assets/map_tiles/panabo_vector/`

### 11. Anti-Spam Moderation

Offline spam detection is implemented.

Current moderation statuses:

- `normal`
- `spam`

Current spam detection rules:

- Compares only messages from the same sender peer ID.
- Ignores messages from different sender peer IDs.
- Looks back within a `10 minute` window.
- Uses Jaccard word similarity.
- Uses normalized Levenshtein similarity.
- Flags spam when:
  - Jaccard similarity is at least `0.80`, or
  - Levenshtein similarity is at least `0.85`.

UI behavior:

- All Messages excludes spam.
- Spam filter shows only spam.
- Spam messages are still stored locally.
- Spam SOS messages do not appear as map markers.

Relevant files:

- `lib/features/messaging/domain/services/spam_detection_service.dart`
- `lib/features/messaging/domain/entities/message_moderation_status.dart`
- `lib/features/messaging/domain/entities/spam_detection_result.dart`
- `lib/features/messaging/presentation/utils/message_feed_filter.dart`

### 12. Messaging UI

Implemented UI areas include:

- Main home page
- SOS composer
- Message feed
- Message filters
- Spam filter behavior
- SOS map and category filters
- Peer cards/status
- Conversation page
- Chat composition page
- Connection status view model

Relevant files:

- `lib/features/messaging/presentation/pages/home_page.dart`
- `lib/features/messaging/presentation/pages/conversation_page.dart`
- `lib/features/messaging/presentation/pages/compose_message_page.dart`
- `lib/features/messaging/presentation/widgets/message_card.dart`
- `lib/features/connectivity/presentation/providers/connection_status_provider.dart`

### 13. App Update Check

The project includes a GitHub app update service and provider.

Relevant files:

- `lib/features/app_update/data/services/github_app_update_service.dart`
- `lib/features/app_update/presentation/providers/app_update_provider.dart`

## Current Tests

The project has focused tests for the important offline messaging behavior.

Current test files:

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

Covered areas include:

- SQLite schema creation and migrations
- Lookup table seeding
- Repository persistence
- SOS payload serialization and hash validation
- Chat payload serialization and hash validation
- Store-Carry-Forward deduplication
- TTL expiry and re-store behavior
- Hop count incrementing on relay
- Per-peer status updates
- Failed delivery retries
- Mock peer relay behavior
- Spam detection from same sender
- Different senders not causing spam classification
- Map marker filtering for non-spam SOS messages

## Current Documentation and Diagram Artifacts

The repository currently includes several generated capstone artifacts:

- `capstone_erd_implemented_crowfoot.png`
- `capstone_erd_implemented_crowfoot.svg`
- `capstone_erd_pure_text.txt`
- `capstone_erd_schema.json`
- `shadow_network_sos_json_schema_diagram.png`
- `shadow_network_sos_json_schema_diagram.svg`
- `shadow_network_use_case_diagram_enhanced.png`
- `shadow_network_use_case_diagram_enhanced.svg`
- `shadow_network_context_flow_diagram.png`
- `shadow_network_context_flow_diagram.svg`
- `shadow_network_dfd_level_1.png`
- `shadow_network_dfd_level_1.svg`
- `shadow_network_conceptual_framework.png`

## Current Known Limitations and Risks

### Battery Use

The relay runtime currently syncs every `4 seconds`. This is good for quick testing with two phones, but too frequent for long disaster deployments. The next improvement should be adaptive duty cycling:

- Foreground/app open: scan every 10-20 seconds.
- After SOS sent/received: scan every 15-30 seconds for the first 5-10 minutes.
- Normal background: scan every 2-5 minutes.
- Low battery: scan every 10-15 minutes.

### Encryption

Payload encryption is not yet implemented. Messages are currently hashed for integrity/deduplication, but not encrypted for privacy. A future secure design should add end-to-end encryption for chat and responder-targeted encryption for SOS details.

### Identity and Trust

Peer identity currently relies on local peer IDs and discovered transport identity. A stronger trust model is still needed for production, such as responder public keys, verified responder profiles, or signed identities.

### Real-Device Transport Validation

The Android BLE/Wi-Fi Direct bridge is implemented, but real-device behavior can vary by Android version, manufacturer, permissions, Wi-Fi Direct prompts, Bluetooth state, and battery restrictions. More physical-device testing is needed.

### Offline Map Coverage

Bundled offline map assets exist for Panabo-focused coverage. If the use area expands to Tagum City or other areas, additional offline tiles and styles must be prepared.

### Firebase Dependency

Core emergency messaging is local/offline, but authentication still uses Firebase. The app should remain usable for emergency messaging even when Firebase or internet access is unavailable.

### Validation Metrics

The app has relay counts and delivery status, but a complete validation metrics dashboard is not yet implemented. Future work should record and display:

- Message delivery success rate
- Node-to-node latency
- End-to-end propagation time
- Hop count distribution
- Battery impact
- Peer discovery success rate

## Recommended Next Work

1. Add adaptive battery-aware relay intervals instead of the current fixed `4 second` sync loop.
2. Add message encryption for chat first, then responder-targeted SOS encryption.
3. Improve peer naming and identity exchange so nearby devices do not appear as generic `BLE Peer`.
4. Add stronger responder trust/verification for emergency workflows.
5. Expand physical testing with at least two Android phones and one relay node.
6. Add a validation metrics screen for capstone testing evidence.
7. Confirm offline map coverage for the final deployment area.
8. Update the basic `README.md` so it no longer says only "A new Flutter project."

## Current State Summary for Adviser

Shadow Network currently has a functioning offline messaging foundation: structured SOS and chat payloads, SQLite local persistence, Store-Carry-Forward relay logic, deterministic message hashes, TTL and hop count handling, spam filtering, offline map support, Android BLE/Wi-Fi Direct transport code, and a foreground relay service for background operation. The next major improvements are battery-aware relay scheduling, message encryption, stronger peer identity, and field validation metrics.

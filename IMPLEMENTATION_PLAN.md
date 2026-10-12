# Shadow Network Implementation Plan

Created: 2026-08-03

Source: `CURRENT_STATE.md`

## Objective

Move Shadow Network from a functioning capstone prototype to a field-testable offline disaster messaging system with stronger cryptography, enforceable device trust, persistent validation metrics, controlled responder-to-admin synchronization, battery-aware background relay, verified offline map coverage, and complete project documentation.

The core SOS and relay path must continue to work without internet. Admin synchronization may be optional and delayed, but message creation, local storage, nearby discovery, and Store-Carry-Forward delivery must never depend on a cloud connection.

## Planning Assumptions

- Android remains the primary mobile platform.
- The browser admin remains a separate PC interface.
- A responder phone is the endpoint for SOS messages and the collection point for field metrics.
- Relay-only devices may carry targeted encrypted payloads without displaying them.
- Suspicious or unverified emergency messages should be retained for review rather than silently deleted.
- Existing SQLite data and payload schema versions must remain readable during migration.
- Work is completed phase by phase, with tests and documentation updated at the end of every phase.

## Priority Overview

| Priority | Workstream | Reason |
|---|---|---|
| P0 | Standard encryption and device keys | Protect targeted SOS and chat content before expanding trust and synchronization |
| P0 | Trust enforcement | Make approval and revocation affect actual message behavior |
| P0 | Persistent validation metrics | Produce defensible capstone evidence from real events |
| P1 | Responder-to-admin synchronization | Move real device and metrics data to the PC dashboard |
| P1 | Battery-aware background relay | Improve practical deployment duration and reliability |
| P1 | Multi-device field validation | Measure real range, delivery, latency, hops, and battery impact |
| P2 | Offline map expansion | Cover the final deployment area without internet dependence |
| P2 | Documentation and release preparation | Make setup, testing, diagrams, and demonstrations reproducible |

## Phase 0: Baseline and Compatibility Guardrails

Estimated effort: 1-2 days

Status: Completed on 2026-08-03

### Tasks

- Tag or record the current verified baseline before protocol changes.
- Preserve support for SOS payload schema versions 1, 2, and 3 during migration.
- Preserve support for chat payload schema version 1 during migration.
- Define a protocol compatibility policy for older devices.
- Add explicit protocol and key-version fields to the planned security contracts.
- Create migration tests before changing the database.
- Document which changes require all test phones to reinstall or clear data.

### Deliverables

- Written payload compatibility policy.
- Database migration test template.
- Security and trust data-contract draft.
- Repeatable baseline verification commands.

### Completion gate

- Current data remains readable.
- The full Phase 0 suite passes all 45 tests.
- `flutter analyze` reports no issues.

## Phase 1: Production-Standard Message Encryption

Estimated effort: 1.5-2.5 weeks

Status: Completed on 2026-08-03

### Goal

Replace the project-specific `sn-sha256-stream-v1` cipher with standard authenticated encryption and extend encryption to targeted chat messages.

### Recommended design

- Generate a long-term X25519 key pair on each Android device.
- Store the private key using Android-backed secure storage, not SQLite or a trust-bundle JSON file.
- Register only the public key with the admin.
- Use an ephemeral X25519 key agreement for each recipient-targeted message.
- Derive a content key with HKDF-SHA-256.
- Encrypt the body with AES-GCM or ChaCha20-Poly1305.
- Authenticate immutable routing and identity fields as additional authenticated data.
- Keep mutable `hop_count` outside the authenticated immutable message content or normalize it consistently.
- Retain SHA-256 message hashes for deduplication, but do not treat hashes as sender signatures.

### Data changes

- Add a new local identity/key metadata store.
- Add trusted-device public-key persistence.
- Add key ID, key version, ephemeral public key, nonce, ciphertext, and authentication tag to encrypted payloads.
- Introduce SOS payload schema version 4.
- Introduce chat payload schema version 2.
- Keep legacy payload parsing and label legacy plaintext or prototype-encrypted messages appropriately.

### Application changes

- Encrypt targeted SOS messages using the selected recipient's registered public key.
- Encrypt targeted chat messages.
- Keep relay payload processing opaque to intermediary devices.
- Reject modified ciphertext and invalid authentication tags.
- Display a clear error when the recipient has no usable public key.
- Prevent silent fallback from targeted encrypted delivery to plaintext delivery.

### Tests

- Key generation and secure reload.
- Encrypt/decrypt round trip.
- Non-recipient decryption failure.
- Modified ciphertext, nonce, tag, or authenticated metadata rejection.
- Relay hop rewriting without exposing or corrupting plaintext.
- SOS v1-v3 compatibility.
- Chat v1 compatibility.
- Missing or rotated key behavior.

### Completion gate

- Targeted SOS and chat payloads contain no plaintext body.
- Only the intended recipient can decrypt using its private key.
- Relay-only devices can forward the envelope unchanged except for allowed routing metadata.
- Legacy payload compatibility and migrations pass automated tests.

## Phase 2: Device Trust and Revocation Enforcement

Estimated effort: 1-1.5 weeks

Status: Implemented and verified on 2026-08-15

### Goal

Make the admin approval state affect sender labeling, recipient selection, message handling, and public-key trust.

### Data changes

Recommended next database migration: version 7.

Add local trust records containing:

- Device ID.
- Owner name.
- Role.
- Status: approved, revoked, or unknown.
- Public key and key version.
- Trust-bundle version or hash.
- Last administrative update.
- Import timestamp.

### Trust-bundle changes

- Add a monotonically increasing bundle version.
- Add issuer ID and signing-key ID.
- Digitally sign the canonical trust-bundle content.
- Verify the signature before replacing the current local trust state.
- Reject older bundles unless the user explicitly confirms a rollback for testing.
- Keep the last valid bundle if a new import fails validation.

### Runtime policy

- Approved sender: display as verified and allow normal delivery.
- Unknown sender: retain and display with an `UNVERIFIED` label because an emergency user may not yet be registered.
- Revoked sender: retain in a quarantine/audit view and exclude from normal feeds and map markers.
- Approved recipient: allow targeted encrypted SOS and chat.
- Missing public key: prevent targeted encrypted sending and explain how to refresh the trust bundle.

Implemented policy: retain revoked-origin payloads for audit, but do not automatically relay them or display them as normal emergency reports. Unknown-origin emergency payloads remain visible and relayable with an Unverified indicator.

### UI changes

- Add Verified, Unverified, and Revoked indicators separate from spam moderation.
- Show trust status and role in message details and receiver selection.
- Add trust-bundle version and last-imported time to the Trust Bundle screen.
- Warn when the bundle is missing or outdated without disabling broadcast emergency messaging.

### Tests

- Signed bundle acceptance and tampered bundle rejection.
- Bundle rollback rejection.
- Approved, unknown, and revoked sender behavior.
- Missing and rotated recipient public key behavior.
- Trust status remains separate from spam status.

### Completion gate

- Admin approval and revocation are enforced in the mobile receive/send pipeline.
- Unknown emergency messages remain available but visibly unverified.
- Trust data survives restart and can be updated safely.

## Phase 3: Persistent Validation Metrics

Estimated effort: 1-2 weeks

Status: Implementation completed and automatically verified on 2026-08-15. Version 8 persists validation sessions and telemetry, the responder interface controls and exports sessions, and calculated values remain unavailable when evidence is insufficient instead of displaying fabricated data. The three-device physical completion gate remains pending because no Android devices were attached during final verification. Automatic phone-to-PC synchronization remains Phase 4 work.

### Goal

Record real measurement events on responder and relay devices so the capstone can calculate delivery, discovery, propagation, hop, and battery metrics without fake values.

### Recommended database additions

Recommended migration after trust work: version 8.

Add tables similar to:

- `validation_sessions`: named test run, environment, start/end time, device role, notes.
- `message_events`: message hash, event type, peer ID, transport, hop count, timestamp, error.
- `discovery_attempts`: scan start/end, discovered count, success state, transport.
- `battery_samples`: battery percentage, charging state, timestamp, runtime mode.
- `metric_sync_batches`: export/sync ID, created time, destination, result, retry state.

### Event instrumentation

Record events for:

- SOS/chat queued.
- Peer discovered.
- Connection attempt started, succeeded, or failed.
- Envelope offered, sent, received, relayed, delivered, expired, or rejected.
- Transport selected and fallback used.
- App/background runtime mode changed.
- Battery sampled at the start, during, and end of a validation session.

### Calculated metrics

- Delivery success rate.
- Peer-discovery success rate.
- Node-to-node latency.
- End-to-end propagation time.
- Hop-count distribution.
- Wi-Fi Direct versus BLE usage and fallback rate.
- Battery percentage consumed per hour or per test session.

### UI changes

- Add a responder validation-session start/stop control.
- Show session name, elapsed time, event count, and sync state.
- Keep operational messaging usable when no validation session is active.
- Add JSON or CSV export for manual backup and adviser review.

### Tests

- Event timestamps and session ownership.
- Delivery and latency calculations.
- Duplicate-event handling.
- Export/import round trip.
- Database migration and restart persistence.

### Completion gate

- A three-device test can create a complete persisted session.
- Every required capstone metric can be calculated from stored events.
- No metric shown in the UI is fabricated.

## Phase 4: Responder-to-PC Admin Synchronization

Estimated effort: 1.5-2.5 weeks

### Goal

Synchronize registered devices, signed trust bundles, validation sessions, and responder-collected metrics with the PC admin dashboard without making emergency delivery depend on the admin computer.

### Recommended capstone architecture

Use a controlled LAN-first synchronization service on the PC:

- A small authenticated API stores the registry, audit log, trust-bundle versions, and metric batches in a persistent PC database.
- The Flutter browser admin reads and writes through that API instead of browser-only `shared_preferences`.
- The responder phone pairs with the admin through a one-time QR code.
- When both devices share a local network or responder hotspot, the phone uploads signed metric batches.
- If the PC is unavailable, the phone queues batches and retries later.
- Manual JSON/CSV export remains available as a fallback.

Cloud hosting may be added later, but it must not become a dependency of SOS creation or SCF relay.

### Admin security

- Add administrator authentication.
- Store password hashes or use a trusted identity provider; never store plaintext passwords.
- Add role-based permissions if multiple admin roles are needed.
- Record registration, approval, revocation, trust-bundle publication, and metric-import events in an audit log.
- Use TLS where possible and authenticate every mobile sync request.
- Reject duplicate or tampered metric batches.

### Migration from browser-local registry

- Read existing browser-local devices once.
- Present a migration preview.
- Import valid records into the PC service.
- Preserve browser storage until server persistence is confirmed.
- Remove direct registry writes to `shared_preferences` after migration.

### Dashboard changes

- Display real validation sessions and metrics.
- Filter by device, role, date, environment, transport, and test session.
- Show pending, approved, revoked, and last-synced device states.
- Export adviser-ready CSV reports.
- Show sync failures and incomplete sessions instead of treating missing data as zero.

### Tests

- Admin authentication and authorization.
- Device approval and revocation persistence.
- Mobile pairing and token expiry.
- Offline queued sync and retry.
- Duplicate batch idempotency.
- Tampered batch rejection.
- Dashboard calculations against known fixtures.

### Completion gate

- Registry data survives browser changes and PC restarts.
- A responder phone can upload a completed validation session.
- The dashboard displays only real synchronized measurements.
- Core offline messaging continues when the admin service is unavailable.

## Phase 5: Battery-Aware and Durable Background Relay

Estimated effort: 1.5-2.5 weeks

### Goal

Reduce battery consumption while improving recovery after backgrounding or process interruption.

### Important current issue

Changing only the four-second Dart synchronization timer is insufficient because the native BLE scanner currently uses continuous low-latency scanning. Duty cycling must control both the Dart synchronization loop and native BLE/Wi-Fi discovery windows.

### Proposed runtime modes

| Mode | Suggested behavior |
|---|---|
| Active emergency | Scan about 15 seconds every 30 seconds for the first 5-10 minutes |
| App in foreground | Scan about 10 seconds every 30-60 seconds |
| Idle background | Scan about 10 seconds every 2-5 minutes |
| Low battery | Scan about 10 seconds every 10-15 minutes |
| Manual sync | Start an immediate discovery and relay window |

These values are initial test settings, not final performance claims. Field measurements should determine the final intervals.

### Native Android work

- Add explicit start/stop discovery-window operations to the transport bridge.
- Move critical queue checks and native scan state ownership into a service-backed component that does not depend entirely on a visible Flutter widget.
- Persist runtime mode and last successful sync.
- Restart safely after activity recreation.
- Use Android scheduling for recovery and maintenance; do not rely on periodic workers for continuous BLE operation.
- Add appropriate handling for reboot, battery optimization, disabled radios, and revoked permissions.
- Keep a visible foreground notification while emergency relay is active.

### UI changes

- Show Active Emergency, Foreground, Background, Low Battery, Paused, and Error states.
- Explain battery-optimization restrictions and provide a direct settings action where Android permits it.
- Allow the user to trigger manual synchronization.
- Do not hide failed permissions or disabled Bluetooth/Wi-Fi states.

### Tests

- Lifecycle pause/resume and activity recreation.
- Queue preservation after process restart.
- Permission revoked while running.
- Bluetooth or Wi-Fi disabled while running.
- Low-battery mode transition.
- Scanner duty-cycle timing.
- No duplicate relay after recovery.

### Completion gate

- Background mode no longer performs continuous low-latency scanning.
- Queued messages survive process interruption.
- The runtime reports its actual mode and failure state.
- Battery tests show measurable improvement without unacceptable delivery loss.

## Phase 6: Structured Multi-Device Field Validation

Estimated effort: 1.5-2 weeks, including repeated trials

### Required devices

- One Resident/User sender phone.
- At least one relay phone.
- One Responder/Rescuer receiver phone.
- One PC running the admin dashboard for post-test synchronization and review.

### Test environments

- Indoor line of sight.
- Indoor with walls or rooms between devices.
- Outdoor line of sight.
- Crowded or radio-noisy location where permitted.
- App foreground.
- Screen locked/background.
- Battery saver enabled.
- BLE-only fallback.
- Wi-Fi Direct preferred transfer.

### Distance matrix

- Indoor: 5, 10, 15, 20, and 25 meters.
- Outdoor: 10, 30, 50, and 70 meters.
- Perform at least 10 attempts for every selected distance and condition.

### Topology matrix

- Direct sender to rescuer.
- Sender to one relay to rescuer.
- Sender through two relays to rescuer.
- Store-Carry-Forward with a moving relay entering range later.
- Targeted encrypted SOS through a relay-only phone.
- Similar-message spam trials using same and different sender IDs.

### Record for every attempt

- Session and trial ID.
- Device models and Android versions.
- Start/end battery level.
- Distance and environment.
- Radio and app state.
- Discovery time.
- Connection time.
- Node-to-node transfer time.
- End-to-end propagation time.
- Delivery result.
- Hop count.
- Transport selected and fallback behavior.
- Error or reason for failure.

### Acceptance targets

Agree on final thresholds with the adviser before testing. Suggested starting targets for controlled tests are:

- At least 90% direct delivery success inside the declared reliable test range.
- At least 80% one-relay delivery success inside the declared topology range.
- Median direct delivery within 60 seconds during active emergency mode.
- Correct non-recipient confidentiality in every targeted-SOS relay trial.
- No spam marker displayed on the SOS map.

### Completion gate

- Results are reproducible and exported from real stored events.
- Claims in the paper use measured ranges and times, not theoretical maximums.
- Failures and environmental limitations are included in the analysis.

## Phase 7: Offline Map, Documentation, and Release Preparation

Estimated effort: 3-5 days plus map-generation time

### Offline map

- Confirm the final deployment boundary with the adviser.
- Generate and bundle all required tiles, fonts, sprites, and styles for that area.
- Add an offline-coverage indicator.
- Add a strict disaster mode that never waits for online fallback.
- Test missing tile behavior and storage size on target phones.

### Documentation

- Replace the default Flutter README.
- Document Android requirements and supported versions.
- Document device installation, permissions, and battery-optimization setup.
- Document fixed-port admin startup and PC synchronization.
- Document device registration, approval, revocation, and trust-bundle refresh.
- Document the three-device field-test procedure.
- Update ERD, JSON schema, DFD, CFD, use case diagram, and data dictionary after schema changes.
- Update `CURRENT_STATE.md` at the completion of every phase.

### Release checks

- Run `flutter analyze`.
- Run `flutter test`.
- Build a debug and release Android APK.
- Build the admin web application.
- Install on all field-test phones without clearing required migration data.
- Test first launch, denied permissions, offline launch, background relay, and app restart.
- Record the exact commit, APK version, and test date used for the capstone demonstration.

### Completion gate

- Setup and demonstration can be repeated from the documentation.
- The final APK, admin build, schema, diagrams, and paper descriptions agree.
- The final adviser claims are backed by recorded field data.

## Milestones

| Milestone | Result |
|---|---|
| M1: Secure Payloads | Standard encrypted targeted SOS and chat with compatible schema migration |
| M2: Enforced Trust | Signed bundles, public keys, and approved/unknown/revoked behavior |
| M3: Measured Relay | Persistent validation events and calculated metrics |
| M4: Real Admin | Authenticated PC persistence and responder metric synchronization |
| M5: Efficient Background | Duty-cycled discovery and improved lifecycle recovery |
| M6: Field Evidence | Multi-device measured delivery, latency, hops, range, and battery impact |
| M7: Capstone Release | Complete maps, documentation, diagrams, builds, and demonstration package |

## Definition of Done for Every Phase

A phase is complete only when:

- Its behavior works without internet where the emergency flow requires it.
- Database and payload migrations preserve supported existing data.
- Denied permissions and unavailable radios produce clear states instead of crashes.
- Pure domain, persistence, and serialization behavior has focused automated tests.
- `flutter analyze` passes.
- `flutter test` passes.
- The Android APK builds when Android code changed.
- The admin web app builds when admin code changed.
- At least one real-device test verifies hardware-related changes.
- `CURRENT_STATE.md` and affected capstone diagrams are updated.

## Estimated Overall Schedule

For one developer, the roadmap is approximately 9-14 weeks, depending on Android device-specific transport issues and the availability of field-test phones. A small team can overlap admin work, metrics instrumentation, map preparation, and documentation after the security contracts are finalized, reducing the schedule to approximately 6-9 weeks.

The schedule should not be shortened by skipping cryptographic key management, migration tests, or field validation. If time is limited, reduce dashboard polish and map coverage before reducing message security, trust correctness, or measurement quality.

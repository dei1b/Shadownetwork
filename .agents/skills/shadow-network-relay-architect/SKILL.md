---
name: shadow-network-relay-architect
description: Implement or review Shadow Network offline SOS and chat relay behavior, SQLite queues, BLE and Wi-Fi Direct transport, payload compatibility, and Store-Carry-Forward state transitions.
---

# Shadow Network Relay Architect

## Read the Current Contract

The Flutter app lives at the repository root. Read `CURRENT_STATE.md` and the relevant sections of `docs/PROTOCOL_COMPATIBILITY.md` before changing payloads or transport behavior. Read `docs/SECURITY_TRUST_CONTRACT.md` and `docs/PHASE_1_ENCRYPTION.md` when a change affects identity, trust, recipients, or encrypted messages. Prefer the current code over stale implementation plans.

Trace the affected flow through these existing components:

- `lib/features/messaging/data/models/relay_payload_codec.dart` and the SOS/chat payload models: encoding, payload type, and message hash.
- `lib/features/messaging/data/services/scf_service.dart`: persisted envelopes, expiry, deduplication, and per-peer delivery state.
- `lib/features/messaging/data/services/scf_relay_service.dart`: peer synchronization and receive/send behavior.
- `lib/features/messaging/domain/services/scf_transport.dart`: the transport contract shared by Android and mock implementations.
- `lib/features/messaging/data/services/android_scf_transport.dart` and `android/app/src/main/kotlin/com/example/shadownetwork/AndroidTransportBridge.kt`: Flutter/native transport boundaries.
- `lib/features/messaging/presentation/providers/relay_runtime_provider.dart`: runtime orchestration and visible relay state.

## Preserve Relay Invariants

- Keep creation, queueing, persistence, and relaying usable without internet or successful Firebase authentication.
- Reuse canonical payload encoding and hashing. Check which fields are included in the hash before changing routing metadata; do not create a competing identity scheme.
- Treat TTL as the existing duration/expiry contract, separately from hop count. Expired envelopes must not re-enter the outbound queue, and a retry must not extend an envelope's lifetime.
- Preserve per-peer attempt and delivery state. A successful transfer to one peer does not establish delivery to the intended recipient.
- Keep encrypted targeted bodies opaque on relay-only devices. Apply the existing trust and revoked-origin rules on both receive and outbound paths.
- Keep database writes consistent with user-facing SOS/chat records and SCF records. Use the existing migration approach when schema changes are required.
- Preserve the mock transport for deterministic tests and demonstrations. Keep widgets focused on rendering and runtime state in Riverpod providers.

## Verify the Changed Behavior

Run `flutter analyze` from the repository root. Choose focused tests matching the affected contract, such as `test/scf_service_test.dart`, `test/mock_scf_transport_test.dart`, payload tests, encryption tests, or trust tests. Add regression coverage for newly introduced relay rules.

For native transport changes, distinguish automated checks from physical-device evidence. Exercise denied permissions, disabled radios, disconnect/reconnect, and pending queue recovery on Android when devices are available; do not claim those checks passed from mock results alone.

Update `CURRENT_STATE.md` and the relevant protocol/security document when observable behavior or a data contract changes. Report the affected flow, verification performed, and any remaining device-only checks.

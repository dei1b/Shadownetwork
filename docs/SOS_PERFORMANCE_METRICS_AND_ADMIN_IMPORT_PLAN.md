# SOS Performance Metrics and Admin Import Plan

## Purpose

This document is the implementation reference for measuring how long an SOS takes to travel between phones, displaying that information on a rescuer device, exporting field-validation data, and importing multiple device datasets into the browser admin dashboard for analysis.

The feature must remain offline-first. SOS creation, Store-Carry-Forward relay, receipt measurement, local persistence, and export must work without internet access. An internet connection may be used later for optional synchronization, but it must not be required for field operation.

## User outcome

A rescuer should be able to see:

- How long ago the victim created an SOS.
- How long the SOS took to reach the rescuer.
- How many hops it traveled.
- Which transport delivered its last hop.
- When it was created and received.

Example compact presentation:

```text
MEDICAL SOS
Received 18 seconds ago
Travel time: 1 min 42 sec
3 hops • Bluetooth
Created: 10:41:08 AM
Received: 10:42:50 AM
```

The rescuer must also be able to export validation data as a file. The browser admin dashboard must import one or more exported files, identify which devices belong to the same field test, and calculate defensible delivery, latency, propagation, hop-count, discovery, transport, and battery metrics.

## Metric definitions

Use these definitions consistently across the mobile UI, exports, tests, and admin dashboard.

| Metric | Definition |
| --- | --- |
| SOS age | Current time minus the SOS origin `createdAt` timestamp. |
| Propagation time | Rescuer `receivedAt` minus SOS origin `createdAt`. |
| Node-to-node latency | Monotonic elapsed time from one phone starting a transfer until that phone receives the next phone's acknowledgement. |
| Hop count | Number of successful device-to-device forwards completed by the SOS. |
| Hop delivery success rate | Acknowledged transfer attempts divided by offered transfer attempts. |
| End-to-end delivery | The intended rescuer successfully stored the SOS. |
| Store-Carry-Forward wait | Propagation time minus the sum of measurable radio-transfer latencies. |

Persist timestamps in UTC. Convert them to the user's local timezone only for display.

Node-to-node latency must use a monotonic timer such as Dart `Stopwatch` or Android `SystemClock.elapsedRealtimeNanos()`. Do not calculate this latency by subtracting timestamps from two different phones, because their clocks may not be synchronized.

Propagation time uses timestamps from different phones. Field-test devices should therefore synchronize their clocks before a test. If `receivedAt` is earlier than `createdAt`, show `Clock mismatch`, retain the underlying record for auditing, and exclude the invalid duration from propagation aggregates.

## Current codebase foundation

The project already contains several required pieces:

- SOS payloads include a creation timestamp, hop count, TTL, and message hash.
- SQLite persists SOS, Store-Carry-Forward envelopes, peers, validation sessions, message events, discovery attempts, and battery samples.
- `ScfRelayService` records offered, sent, received, relayed, rejected, and delivered validation events.
- `ValidationMetricsCalculator` calculates initial success, latency, propagation, hop, discovery, fallback, and battery summaries.
- The responder-only `/validation` page starts sessions and exports JSON or CSV to the clipboard.
- The browser admin dashboard's Validation Metrics card is currently a hard-coded `No data` placeholder.

The original write-only latency limitation is resolved by Phase 2 below:
`sendEnvelope()` now completes only after the next phone confirms storage.

## Phase 1: Persist rescuer receipt information

Status: implemented on 2026-10-13. SQLite schema version 10 adds the four
nullable receipt columns. Incoming plain and encrypted SOS messages record the
receiving phone's UTC acceptance time, independently of the previous phone's
envelope timestamp. Android and mock transports pass available last-hop context
to the SOS repository. Repeated deliveries and status updates retain the first
receipt. Locally created SOS messages and legacy rows retain null receipt times.

`propagationDuration` is derived from the timestamps and returns null for
missing receipts or negative clock intervals. No receipt metadata is added to
the originating SOS payload or message hash. Transfer IDs remain null until a
transport supplies them in Phase 2; a BLE sender's peer ID may also be null until
its identity has been resolved. Receipt display remains Phase 3.

Regression coverage: schema creation and upgrades from versions 5, 8, and 9;
receipt persistence across database reopen; UTC serialization; clock mismatch;
first-receipt preservation; native channel compatibility; and the runtime
receive flow for plain, encrypted, and returned local SOS messages.

### Domain changes

Update `lib/features/messaging/domain/entities/sos_message.dart` with:

```dart
final DateTime? receivedAt;
final String? receivedFromPeerId;
final String? receivedTransport;
final String? transferId;

Duration? get propagationDuration {
  if (receivedAt == null) return null;
  final duration = receivedAt!.difference(createdAt);
  return duration.isNegative ? null : duration;
}
```

Do not store formatted labels or a derived propagation duration. Store the source timestamps and calculate display values from them.

### SQLite migration

Increment `LocalMessagingDatabase.databaseVersion` and add a migration in `lib/features/messaging/data/datasources/local_messaging_database.dart`:

```sql
ALTER TABLE sos_messages ADD COLUMN received_at TEXT;
ALTER TABLE sos_messages ADD COLUMN received_from_peer_id TEXT;
ALTER TABLE sos_messages ADD COLUMN received_transport TEXT;
ALTER TABLE sos_messages ADD COLUMN transfer_id TEXT;
```

Update `SosMessageModel.fromMap()` and `SosMessageModel.toMap()` in `lib/features/messaging/data/models/sos_message_model.dart`.

When an incoming SOS is persisted in `relay_runtime_provider.dart`, set `receivedAt` from the receiving device's current UTC time. Do not reuse `updatedAt`, because that timestamp may change for unrelated state transitions.

For SOS messages created locally, `receivedAt` should normally remain null unless the same device is also acting as the final responder.

## Phase 2: Add acknowledged hop transfers

Status: implemented. Android transport protocol is now **2** and SQLite schema
is **11**. Update every sender, relay, and rescuer phone to the same build before
testing; protocol-1 peers are incompatible. Upgrade in place without clearing
app data. SOS/chat payload schemas, canonical message hashes, encryption, TTL,
and first-receipt preservation are unchanged.

Implementation notes for the next agent:

- Each hop attempt, including retries, gets a fresh 128-bit random transfer ID.
- Flutter sends `stored` only after SCF SQLite persistence, hash/TTL checks,
  and origin-trust evaluation. Active duplicates can ACK again without another
  stored record or hop increment. Revoked messages return `rejected` while
  remaining available to the runtime for quarantine. Storage failures, bad
  hashes, and expired envelopes never receive `stored`.
- `stored` confirms next-hop envelope acceptance, not recipient decryption,
  SOS display, rescuer action, or cryptographic sender authenticity.
  `envelopeDelivered` remains a separate final-recipient event.
- Wi-Fi Direct returns ACKs over the existing TCP socket. BLE polls a new
  readable ACK characteristic on the same GATT connection every 200 ms.
- The ACK deadline is 10 seconds **after** the write completes. Existing
  connection/setup/write deadlines remain separate. Native monotonic latency
  includes setup, writing, and storage ACK for the actual successful transport;
  a BLE fallback measurement excludes the failed Wi-Fi attempt. Wall-clock
  timestamps are retained for auditing, not subtracted for node latency.
- ACK matching requires transfer ID, hash, receiver peer, and actual transport.
  Pending state is cleared on completion/failure/stop/connection closure.
  ACK timeout and receiver rejection do not trigger radio fallback; SCF can retry.
- Incoming processing runs independently of outbound ACK waits to avoid
  simultaneous-send deadlock. A lost outgoing ACK never hides a stored SOS.
- Validation events have indexed `transfer_id` storage. JSON/CSV retain it;
  the existing session-export schema remains 1 with an optional added field.
  Legacy events without IDs remain readable but cannot establish hop success
  or ACK-based latency. Portable schema-2 bundles remain Phase 5.
- Hop success deduplicates IDs and requires matching offered/acknowledged
  peer/hash evidence. Receiver-only/legacy datasets show unavailable success,
  not an inferred percentage.

Automated coverage includes simultaneous runtime sends, matching/duplicate/wrong
ACKs, timeout with completed-write evidence, retry IDs, duplicate storage,
expired/hash-invalid/revoked/storage-failed reception, lost ACKs, native-channel
contracts, migration 10-to-11, and event persistence/export after restart.
Physical BLE/Wi-Fi Direct ACK, radio/permission failures, stop/disconnect,
fallback, and multi-hop validation still require Android phones. Receipt UI and
browser admin import are not implemented in this phase; continue with Phase 3.

Verification: `flutter analyze` reported no issues, all **120** Flutter tests
passed, and `flutter build apk --debug` produced the Android APK with the native
protocol-2 changes compiled. These checks are not physical-device evidence.

### Envelope contract

Every individual hop attempt needs a unique `transferId`. A message hash identifies the logical SOS, whereas a transfer ID identifies one attempt to send it to one peer.

```json
{
  "type": "envelope",
  "protocolVersion": 2,
  "transferId": "unique-transfer-attempt-id",
  "messageHash": "original-message-hash",
  "sourcePeerId": "phone-a",
  "hopCount": 3,
  "payloadJson": "..."
}
```

After the receiving phone persists the envelope, it should return:

```json
{
  "type": "envelope_ack",
  "transferId": "unique-transfer-attempt-id",
  "messageHash": "original-message-hash",
  "receiverPeerId": "phone-b",
  "status": "stored"
}
```

### Android transport work

Update `android/app/src/main/kotlin/com/example/shadownetwork/AndroidTransportBridge.kt`:

1. Increment `PROTOCOL_VERSION` because the frame contract changes.
2. Include `transferId` and `sourcePeerId` in envelope frames.
3. Add handling for `envelope_ack` frames.
4. Maintain pending transfers keyed by `transferId`.
5. Start a monotonic timer before sending an envelope.
6. Complete the pending transfer when the matching acknowledgement arrives.
7. Fail the attempt after a bounded timeout, initially 10 seconds.
8. Ignore duplicate acknowledgements safely.
9. Remove pending entries after success, failure, cancellation, or connection closure.

The receiver should acknowledge successful persistence, not merely native inbox enqueueing. One implementation is to retain the inbound connection and expose an `acknowledgeEnvelope` method over the Flutter method channel. Flutter calls it only after the SQLite operation succeeds.

If transport-level and storage-level acknowledgements are both introduced, name them explicitly:

- `transport_received`: native transport reconstructed the full frame.
- `stored`: Flutter persisted and accepted the envelope.

Use the `stored` acknowledgement for delivery success. Transport receipt can remain a diagnostic metric.

### Dart transport work

Extend `EnvelopeTransferResult` with:

```dart
final String transferId;
final bool acknowledged;
final int latencyMs;
final DateTime? acknowledgedAt;
```

The result should be returned only after acknowledgement or should throw a typed timeout/transport failure.

### Validation events

Add:

```dart
ValidationEventType.envelopeAcknowledged
```

Keep these meanings separate:

- `envelopeOffered`: a transfer attempt was selected.
- `envelopeSent`: the transport write completed.
- `envelopeAcknowledged`: the next phone confirmed storage.
- `envelopeDelivered`: the intended rescuer accepted the SOS.
- `envelopeRejected`: validation, timeout, or transport failure occurred.

Add `transferId` as a first-class validation-event field and SQLite column. Do not hide it only inside `metadata`, because it is required for cross-device correlation and indexing.

Calculate hop delivery success as:

```text
unique acknowledged transfer IDs / unique offered transfer IDs
```

## Phase 3: Display timing on the rescuer phone

Update the SOS list/card implementation in `lib/features/messaging/presentation/pages/home_page.dart`.

### Compact SOS card

Show:

- `Received 18s ago`
- `Travel time 1m 42s • 3 hops`
- Last-hop transport when known

Formatting rules:

- Less than one minute: `18s`
- Less than one hour: `12m 08s`
- One hour or more: `1h 14m`
- Zero hops: `Direct`
- One or more hops: `1 hop`, `3 hops`, and so on
- Missing receipt information: `Propagation time unavailable`
- Negative duration: `Clock mismatch detected`

### SOS detail sheet

Show:

- Created time
- Received time
- Propagation duration
- Hop count
- Last transport
- Sender
- Last relay peer
- Shortened message hash with a copy action
- GPS accuracy
- TTL remaining or expiration state
- Trust and moderation state already associated with the message

Use a lightweight clock provider or scoped timer to refresh relative labels. Do not update SQLite every second, and avoid rebuilding the complete application shell solely to update elapsed-time text.

## Phase 4: Add a shared field-test identity

Every device participating in the same experiment needs a common `testRunId`. Session names are human-entered and are not reliable correlation keys.

Extend validation sessions with:

```dart
final String testRunId;
```

Allow a responder to:

- Enter a short run code, such as `PANABO-2026-001`.
- Scan a test-run QR code generated by the lead rescuer/admin.
- Reuse the active run code when starting a validation session.

Correlation keys:

| Key | Purpose |
| --- | --- |
| `testRunId` | Groups all devices participating in one field test. |
| `messageHash` | Identifies one logical SOS across the mesh. |
| `transferId` | Identifies one specific node-to-node attempt. |
| `deviceId` | Identifies the device that produced an event. |
| `bundleId` | Identifies one exported dataset and prevents duplicate import. |

## Phase 5: Create a portable validation bundle

The current clipboard export should remain available for debugging, but field use needs a real `.json` file that can be shared from Android and imported into Flutter Web.

Create export schema version 2:

```json
{
  "schema_version": 2,
  "bundle_type": "shadow_network_validation_bundle",
  "bundle_id": "unique-export-id",
  "generated_at": "2026-10-13T02:45:00Z",
  "payload_hash": "sha256-of-canonical-bundle-content",
  "test_run": {
    "id": "PANABO-2026-001",
    "name": "Three-phone outdoor test",
    "environment": "Outdoor field test"
  },
  "device": {
    "peer_id": "rescuer-device-id",
    "role": "responder",
    "app_version": "0.1.0",
    "protocol_version": 2
  },
  "sos_receipts": [
    {
      "message_hash": "...",
      "category": "medical",
      "created_at": "...",
      "received_at": "...",
      "propagation_ms": 102000,
      "hop_count": 3,
      "last_peer_id": "relay-c",
      "transport": "bluetooth"
    }
  ],
  "message_events": [],
  "discovery_attempts": [],
  "battery_samples": []
}
```

Export requirements:

- Generate a unique `bundleId` for every export.
- Include app and transport protocol versions.
- Include a SHA-256 checksum over canonical export content.
- Preserve the existing schema-version-1 decoder for backward compatibility.
- Write the export to a file using application temporary/support storage.
- Open the Android share sheet so the rescuer can copy it through USB, Nearby Share, email after connectivity returns, or another available channel.
- Use a predictable filename such as `shadow-network-PANABO-2026-001-rescuer-device-20261013T104500.json`.
- Record the successful export in `metric_sync_batches`.

### Privacy default

Validation bundles should exclude these fields by default:

- SOS body text
- Exact victim coordinates
- Authentication tokens
- Private encryption keys
- Raw encrypted message bodies when not required for metrics

Category, timing, hop, transport, anonymized device identifiers, and hashes are sufficient for performance analysis. If precise locations are needed for a separate research question, require an explicit opt-in export mode.

## Phase 6: Implement admin dashboard import

Replace the hard-coded Validation Metrics card in `lib/features/admin/presentation/pages/browser_admin_dashboard_page.dart` with provider-backed data.

Suggested module structure:

```text
lib/features/admin_validation/
  data/
    repositories/browser_validation_import_repository.dart
  domain/
    entities/imported_validation_bundle.dart
    repositories/validation_import_repository.dart
    services/validation_bundle_aggregator.dart
    services/validation_bundle_validator.dart
  presentation/
    providers/admin_validation_provider.dart
    widgets/validation_import_panel.dart
    widgets/validation_analysis_panel.dart
```

### Import behavior

The dashboard should provide:

- An `Import validation data` file button.
- Optional drag-and-drop support.
- Multi-file selection.
- JSON schema and bundle-type validation.
- Checksum verification.
- Schema-version compatibility checks.
- Duplicate detection by `bundleId`.
- A preview before committing the import.
- Persistent browser storage using IndexedDB.
- A list of imported bundles with device, role, run, date, and record count.
- Remove and re-import actions.
- Clear error messages for malformed or unsupported files.

Do not depend on the mobile SQLite database from Flutter Web. The admin dashboard consumes portable bundles and maintains its own browser-side import repository.

## Phase 7: Build admin analysis

Replace the `No data` values with aggregates calculated from imported bundles.

### Summary metrics

- Number of imported devices
- Number of received SOS messages
- Hop delivery success rate
- Failed/timeout transfer count
- Median node-to-node latency
- P95 node-to-node latency
- Average and median end-to-end propagation
- Hop-count distribution
- BLE versus Wi-Fi Direct usage
- Transport fallback rate
- Peer discovery success rate
- Battery consumed per hour

Median and P95 should be shown alongside the average. An average alone can hide sporadic but operationally important slow transfers.

### Filters

- Test run
- Device
- Device role
- Date range
- Transport
- SOS category
- Hop count
- Successful versus failed attempt

### Data completeness

A rescuer-only bundle can calculate:

- Received SOS count
- End-to-end propagation time
- Final hop-count distribution
- Last-hop transport usage
- Rescuer battery and discovery metrics

It cannot calculate a complete delivery success rate because it does not contain unsuccessful sender attempts. The dashboard must not display a misleading percentage. Show:

```text
Partial dataset
1 responder bundle imported. Import sender and relay bundles to calculate
delivery success and reconstruct every hop.
```

Only calculate hop success when offered and acknowledged attempts are available for the selected scope.

## Phase 8: Reconstruct message paths

After multiple device bundles from one `testRunId` are imported, join records by `messageHash` and `transferId`.

Example admin output:

```text
Victim A -> Relay B -> Relay C -> Rescuer D
            420 ms     610 ms      530 ms

Measured radio-transfer latency: 1.56 s
Store-Carry-Forward waiting: 2 min 14 s
End-to-end propagation: 2 min 15.56 s
Final hop count: 3
```

If a link is missing because a device export was not imported, show an explicit unknown segment rather than inferring a measurement.

## Metric calculation rules

### Hop delivery success

```text
unique acknowledged transfer IDs / unique offered transfer IDs
```

Deduplicate retransmitted telemetry by `transferId` and event type before calculating.

### Node latency

Calculate from acknowledged events that contain a valid monotonic `latencyMs`.

Report:

- Count
- Minimum
- Median
- Mean
- P95
- Maximum

### End-to-end propagation

For each final rescuer receipt:

```text
receivedAt - createdAt
```

Exclude negative durations from aggregates and count them as clock-skew warnings.

### Hop distribution

Use only final rescuer receipts when reporting end-to-end hop distribution. Do not count the same message once on every relay unless the chart is explicitly labeled as relay-observation distribution.

### Battery impact

Only calculate battery drain across two or more samples from a non-charging period. Report both percentage consumed and percentage consumed per hour. Keep samples grouped by device because battery characteristics differ between phone models.

## Test plan

### Unit and database tests

- Database migration from version 9 to the new version preserves existing SOS and validation records.
- `receivedAt`, transport, source peer, and transfer ID survive SQLite round trips.
- Propagation duration is calculated correctly.
- Negative propagation is flagged as clock skew.
- Hop count increments exactly once for a successful relay.
- ACK success completes the correct pending transfer.
- ACK timeout produces a failed validation event.
- Duplicate ACKs do not duplicate success records.
- Transfer IDs are unique per attempt, including retries of the same message hash.
- Export schema version 2 round-trips without losing data.
- Version 1 exports remain importable.
- Export checksum validation detects changed content.
- Admin import rejects malformed or unsupported bundles.
- Admin import deduplicates an existing `bundleId`.
- Multi-device aggregation joins records correctly.
- Median and P95 calculations are deterministic.
- Partial datasets suppress unsupported success-rate claims.

### Widget tests

- Rescuer SOS card displays age, propagation, hop count, and transport.
- Missing receipt information displays the fallback label.
- Clock skew displays a warning.
- Admin import preview displays bundle identity and record count.
- Admin summary updates after import.
- Admin completeness warning changes after sender/relay bundles are added.

### Physical-device validation

Run at least these scenarios:

1. Direct victim-to-rescuer transfer.
2. One-relay transfer.
3. Two-relay transfer.
4. BLE-only transfer.
5. Wi-Fi Direct transfer.
6. Wi-Fi Direct failure followed by Bluetooth fallback.
7. Duplicate SOS reception.
8. Sender or relay disappears before acknowledgement.
9. Application restarts before export.
10. Multiple exports from the same run are imported into the dashboard.
11. The same bundle is imported twice.
12. One device has an intentionally incorrect clock.

Before each propagation experiment, synchronize the participating phones' wall clocks as closely as practical and record the setup in the validation-session notes.

## Recommended implementation order

1. Add `receivedAt` and receipt metadata to the SOS model and SQLite schema.
2. Display age, propagation time, and hop count on rescuer SOS cards.
3. Add `transferId`, stored acknowledgements, timeout handling, and accurate hop latency.
4. Add `testRunId` to validation sessions.
5. Generate shareable version-2 validation bundle files.
6. Implement browser file import, validation, deduplication, and IndexedDB persistence.
7. Replace the admin placeholder card with real summaries and completeness warnings.
8. Add filters, distributions, CSV output, and path reconstruction.
9. Complete mock, unit, widget, migration, and physical-device testing.

This order delivers immediate rescuer value first, then adds measurement accuracy, and finally builds the multi-device capstone analysis workflow.

## Definition of done

The feature is complete when:

- A received SOS persists its origin creation time and rescuer receipt time across app restarts.
- The rescuer sees age, propagation time, hop count, and last-hop transport.
- Every hop attempt has a unique transfer ID.
- A successful hop requires a receiver acknowledgement.
- Timeouts and transport failures are persisted as validation events.
- A responder can export a real validation JSON file without internet.
- The admin dashboard can import, validate, persist, remove, and re-import bundles.
- Duplicate bundles do not inflate results.
- Admin metrics clearly distinguish complete and partial datasets.
- Multiple device bundles from one test run can reconstruct message paths.
- Existing schema-version-1 validation exports remain supported.
- `flutter analyze` passes.
- Focused unit, migration, widget, and transport tests pass.
- The complete workflow has been demonstrated on at least two physical Android phones with mobile data disabled.

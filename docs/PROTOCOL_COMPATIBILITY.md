# Shadow Network Protocol Compatibility Policy

Status: Updated for sender signatures and service recovery

Updated: 2026-10-20

## Purpose

This policy defines how Shadow Network devices handle database versions, transport protocol versions, message payload schemas, trust bundles, and encryption suites after the Phase 1 secure-payload rollout.

## Compatibility Principles

1. Read old, write current. A release may read supported legacy payloads but writes only its declared current schema.
2. Never silently reinterpret unknown schemas. Unsupported future versions must be rejected and retained as opaque relay envelopes only when safe.
3. Never silently downgrade targeted content to plaintext. If encryption cannot be completed, the targeted send must fail with a clear error.
4. Relay without decrypting. An intermediary needs envelope routing metadata and a stable hash, not message plaintext or recipient private keys.
5. Migrate databases sequentially. Every released database version requires an upgrade test with existing data.
6. Preserve emergency evidence. Invalid, revoked, spam, or incompatible records should be quarantined or logged instead of silently deleted.
7. Transport compatibility and payload compatibility are separate. A device may complete a transport handshake but still reject an unsupported payload schema.

## Current Compatibility Matrix

| Layer | Current writer | Supported readers | Unknown future version |
|---|---:|---|---|
| SQLite database | 12 | Sequential migrations 1 through 12 | App must not open without a defined migration |
| Android transport handshake/frame | 2 | Exact protocol version 2 | Reject as incompatible peer |
| SOS payload | 5 | 1, 2, 3, 4, 5 | Reject visible parsing; do not guess fields |
| Chat payload | 3 | 1, 2, 3 | Reject visible parsing; do not guess fields |
| Trust bundle | 2 | Signed schema 2 | Reject import and keep last valid bundle |
| Targeted message security | `x25519-hkdf-sha256-aes-256-gcm-v1` | SOS v4 and chat v2 | Reject unknown algorithm, key, or authentication tag |
| Legacy targeted SOS security | `sn-sha256-stream-v1` | SOS v3 read compatibility only | Never use for new outgoing messages |

## Current Mixed-Version Behavior

### Barangay SOS categories

- The composer and map filters offer only Medical Assistance (`medical`), Fire & Electrical Danger (`fireElectrical`), Safety Threat (`safetyThreat`), Flood & Rescue (`rescue`), Immediate Public Hazard (`publicHazard`), and Other Urgent Assistance (`other`).
- Database version 9 seeds the new lookup codes without renaming or deleting existing SOS records, hashes, or queued envelopes. Upgrade in place without clearing app data.
- Retired `food`, `water`, `shelter`, `transport`, and `information` codes remain readable for historical data and incoming legacy messages. They are not selectable for new SOS messages; their map records are included under Other Urgent Assistance.
- The SOS JSON shape and schema version remain unchanged. Older apps cannot display the three new category codes. Update all sender, responder, and relay phones before testing these categories together; matching schema numbers alone do not guarantee category compatibility.
- Delivery and relay statuses are unchanged. This update adds no responder acknowledgment or resolution workflow.

### SOS

- Schema 1 is accepted as a legacy broadcast SOS with the default 24-hour TTL.
- Schema 2 is accepted as a hashed structured broadcast SOS.
- Schema 3 remains readable and supports broadcast or targeted prototype-encrypted SOS.
- Schema 4 remains a legacy reader. Schema 5 is the current signed writer. Targeted bodies use X25519, HKDF-SHA-256, and AES-256-GCM.
- A relay may update allowed hop metadata without changing the stable message hash.
- A non-recipient does not parse a targeted SOS into a visible message.

### Chat

- Schema 3 is the current signed, encrypted targeted-chat writer; schemas 1 and 2 remain readable as unverified legacy records.
- A non-recipient stores and relays the envelope without adding it to a visible conversation.

### Android transport

- BLE identity, Wi-Fi Direct DNS-SD, socket hello, and envelope frames use transport protocol version 2.
- Version 2 requires an exact protocol match. Update all test phones together; protocol 1 cannot participate in acknowledged transfers.
- An app ID or protocol mismatch must not appear as a valid nearby Shadow Network peer.
- Envelope frames add `transferId` and `sourcePeerId`; each retry uses a new ID without changing message hash, TTL, or the originating payload schema.
- Flutter acknowledges SQLite envelope acceptance with `envelope_ack`, matching `transferId`, `messageHash`, `receiverPeerId`, and `status` (`stored` or `rejected`). Active duplicate envelopes can be acknowledged again; expired, hash-invalid, revoked, or storage-failed envelopes cannot receive `stored`.
- Wi-Fi Direct uses the same socket; BLE uses readable GATT ACK UUID `9f7a7773-1b31-4f1d-8f99-6d7a9f50a101` on the same connection (200 ms polling). A write alone is not success.
- The storage-ACK deadline is 10 seconds after transport write completion, separately from connection/write deadlines. Measured monotonic latency starts before actual transport setup and ends at the matching stored ACK. For fallback, it measures the successful BLE attempt, excluding the failed Wi-Fi setup/write.
- ACKs confirm next-hop storage, not intended-recipient decryption, visible delivery, or rescuer resolution. ACKs are not signed; matching radio-session/peer/hash/ID context is correlation, not cryptographic authentication.
- Schema 10 preserves first SOS receipt metadata; schema 11 adds nullable indexed `message_events.transfer_id`. Existing rows migrate in place without clearing data. Legacy validation exports remain readable; write-only latency and missing-ID events do not establish acknowledged-hop metrics.

## Phase 1 Rollout Rules

The secure payload rollout was completed in this order:

1. Added readers for SOS schema 4, chat schema 2, and the selected standard encryption suite while keeping legacy readers.
2. Generate device key pairs and register public keys.
3. Publish and import a trust bundle containing recipient public keys and key versions.
4. Confirm all intended recipient devices can read the new schemas.
5. Switched production targeted SOS and chat writers to the new schemas.
6. Keep legacy readers for the documented support window.
7. Remove a legacy reader only after test devices and retained payload evidence no longer require it.

There must be no writer switch before recipients have the required reader and key material.

## Implemented Version Allocation

| Contract | Current version | Purpose |
|---|---:|---|
| SQLite database | 12 | Prior data plus device signing keys and verified-label correction |
| SOS payload | 5 | Ed25519 sender signature plus existing recipient encryption |
| Chat payload | 3 | Ed25519 sender signature plus existing recipient encryption |
| Trust bundle | 2 | Bundle version, public keys, issuer, and signature |
| Transport protocol | 2 | Per-attempt identity and receiver-storage ACK framing |

Transport 2 is independent of the unchanged targeted-message encryption suite.

## Sender-signature rollout (2026-10-20)

1. Update all participating phones without clearing app data. Transport remains version 2, but older applications cannot accept the new payload schemas.
2. Show the new version-2 registration QR. The administrator verifies its self signature, records the user name/role and both public keys, approves the registration and exports a newer signed bundle.
3. Import that bundle on all sender, relay and responder phones. Responder role access requires both registered keys to match the phone.
4. Outgoing SOS 5/chat 3 always include an Ed25519 signature. Helpers still support explicit legacy fixtures. Signed hashes use canonical JSON of the full payload except `message_hash`, with `routing.hop_count` normalized to zero. Signature input uses the same normalization, excludes the signature value, and adds the domain `shadow-network-sender-signature-v1` followed by a newline. New encrypted schemas use canonical JSON for additional authenticated data; old schemas retain their exact original hash/AAD behavior.
5. Validate at both inbound acceptance and outbound transfer. A bad/missing required signature or registered-key mismatch rejects transfer. Unknown self-signed origins remain unverified and relayable. Revoked origins remain quarantined and receive a rejected ACK. Legacy unsigned messages never receive Verified from a claimed device ID.
6. Original signed creation time plus TTL caps envelope expiry. Neither retry nor relay metadata can extend it. Hop count remains an observational routing field, not proof of the physical route.
7. Replacing keys requires fresh approval. Old queued signatures do not verify under replacement keys; already stored history is retained. There is no historical retired-key acceptance mechanism yet.

Trust bundles remain signed schema 2 with an optional `signing_public_key` field per device. Existing bundles stay readable. QR schema 1 remains parseable for legacy fixtures, but the admin scanner requires signed QR schema 2 for new automatic registration.

## Failure Handling

- Unsupported payload schema: retain the SCF envelope until expiry when safe, record an incompatibility event, and do not display malformed content.
- Unsupported encryption suite or key version: do not decrypt, do not display ciphertext as text, and show the intended recipient an actionable error.
- Missing recipient key: block targeted sending; never broadcast the plaintext as fallback.
- Invalid message hash or authentication tag: reject visible persistence and record the validation failure.
- Newer trust bundle: reject import, preserve the current valid bundle, and request an app update.
- Older signed trust bundle: reject rollback unless an explicit development-only override is used and recorded.
- Missing database migration: fail safely and preserve the database file for recovery.

## Required Tests for Every New Version

- Old fixture remains readable.
- New fixture round trips.
- Fixed canonical hash or signature remains stable.
- Unknown future version is rejected.
- Mixed old/new relay does not corrupt hop count or message hash.
- Database upgrade preserves representative existing rows.
- Failed upgrade does not delete the original database.

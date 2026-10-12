# Shadow Network Protocol Compatibility Policy

Status: Updated through Phase 1 secure-payload rollout

Updated: 2026-08-03

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
| SQLite database | 6 | Sequential migrations 1 through 6 | App must not open without a defined migration |
| Android transport handshake | 1 | Exact protocol version 1 | Reject as incompatible peer |
| SOS payload | 4 | 1, 2, 3, 4 | Reject visible parsing; do not guess fields |
| Chat payload | 2 | 1, 2 | Reject visible parsing; do not guess fields |
| Trust bundle | 1 | 1 | Reject import and keep last valid bundle |
| Targeted message security | `x25519-hkdf-sha256-aes-256-gcm-v1` | SOS v4 and chat v2 | Reject unknown algorithm, key, or authentication tag |
| Legacy targeted SOS security | `sn-sha256-stream-v1` | SOS v3 read compatibility only | Never use for new outgoing messages |

## Current Mixed-Version Behavior

### SOS

- Schema 1 is accepted as a legacy broadcast SOS with the default 24-hour TTL.
- Schema 2 is accepted as a hashed structured broadcast SOS.
- Schema 3 remains readable and supports broadcast or targeted prototype-encrypted SOS.
- Schema 4 is the current writer. Targeted bodies use X25519, HKDF-SHA-256, and AES-256-GCM.
- A relay may update allowed hop metadata without changing the stable message hash.
- A non-recipient does not parse a targeted SOS into a visible message.

### Chat

- Schema 1 is the only supported chat schema.
- Chat is recipient-targeted but currently plaintext inside its envelope.
- A non-recipient stores and relays the envelope without adding it to a visible conversation.

### Android transport

- BLE identity, Wi-Fi Direct DNS-SD, and socket hello messages advertise transport protocol version 1.
- Version 1 currently requires an exact protocol match.
- An app ID or protocol mismatch must not appear as a valid nearby Shadow Network peer.

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

## Planned Version Allocation

| Contract | Planned next version | Purpose |
|---|---:|---|
| SQLite database | 7 | Trusted device, public-key, and trust-bundle metadata |
| SOS payload | 4 | Standard recipient encryption and explicit security versioning |
| Chat payload | 2 | Standard recipient encryption |
| Trust bundle | 2 | Bundle version, public keys, issuer, and signature |
| Transport protocol | Remains 1 unless framing changes | Payload security alone does not require a transport bump |

Version numbers are reservations for planning. If implementation requirements change, update this document before merging code.

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

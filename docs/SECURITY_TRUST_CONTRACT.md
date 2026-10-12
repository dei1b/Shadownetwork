# Shadow Network Security and Trust Contract Draft

Status: Phase 1 encryption and Phase 2 signed trust enforcement implemented

Updated: 2026-08-15

## Scope

This document defines the implemented security boundaries for standard targeted-message encryption and signed device trust. Sender message signatures and secure multi-admin key management remain future hardening work.

## Security Goals

- Only the intended recipient can read a targeted SOS or chat body.
- Relay devices can store and forward encrypted payloads without private keys.
- The recipient can detect modified ciphertext and immutable metadata.
- Device approval binds a device ID, role, and public key.
- Revocation can be distributed offline in a signed trust bundle.
- Message security remains independent of internet or cloud availability.

## Threats in Scope

- A relay user trying to read targeted message content.
- A device modifying ciphertext or immutable sender/recipient metadata.
- A troll registering or impersonating a responder device.
- A modified or forged trust-bundle JSON file.
- Replay or rollback to an older trust bundle.
- Loss or rotation of a recipient public key.

## Threats Not Fully Solved by This Contract

- A physically compromised unlocked recipient phone.
- Traffic analysis from visible sender, recipient, timing, size, or routing metadata.
- Denial of service through radio interference or deliberate resource exhaustion.
- False emergency content submitted by an otherwise approved user.
- Permanent identity across factory resets without an external registration process.

## Planned Device Identity Contract

Each device should maintain:

```json
{
  "device_id": "local-device-ab12cd34",
  "identity_version": 1,
  "key_id": "device-key-2026-001",
  "key_version": 1,
  "key_algorithm": "x25519",
  "public_key": "base64url-public-key",
  "created_at": "2026-08-03T00:00:00Z"
}
```

Rules:

- The private key never appears in SQLite, logs, QR trust bundles, payloads, or admin exports.
- Android-backed secure storage holds the private key.
- Public-key rotation creates a new key ID and increments key version.
- The admin must explicitly approve a replacement key for an existing device ID.

## Planned Payload Protocol Fields

Each new secure payload should declare both payload and security compatibility explicitly:

```json
{
  "protocol": {
    "app_id": "shadownetwork",
    "transport_protocol_version": 1,
    "payload_schema_version": 4
  },
  "security": {
    "encrypted": true,
    "security_version": 1,
    "suite": "x25519-hkdf-sha256-aes256gcm-v1",
    "recipient_key_id": "device-key-2026-001",
    "recipient_key_version": 1,
    "ephemeral_public_key": "base64url-ephemeral-public-key",
    "nonce": "base64url-nonce",
    "ciphertext": "base64url-ciphertext",
    "tag": "base64url-authentication-tag"
  }
}
```

Phase 1 selected AES-256-GCM. The implemented suite identifier is `x25519-hkdf-sha256-aes-256-gcm-v1`.

## Encryption Inputs

Recommended construction:

1. Generate an ephemeral X25519 key pair for the message.
2. Perform X25519 agreement with the recipient's approved public key.
3. Derive the message key using HKDF-SHA-256 with a protocol-specific context string.
4. Generate a cryptographically random nonce of the required length.
5. Encrypt the body with AES-GCM or ChaCha20-Poly1305.
6. Authenticate immutable metadata as additional authenticated data.

Recommended authenticated metadata:

- App ID.
- Payload schema version.
- Security version and suite.
- Message ID.
- Message hash contract version.
- Sender peer ID.
- Recipient peer ID.
- Recipient key ID and key version.
- Category.
- Creation timestamp.
- TTL.

Do not authenticate mutable hop count as immutable content. Hop count must remain relay-editable while the original protected message identity remains stable.

## Planned Signed Trust Bundle Version 2

```json
{
  "schema_version": 2,
  "bundle_type": "shadow_network_device_trust_bundle",
  "bundle_version": 42,
  "issued_at": "2026-08-03T00:00:00Z",
  "expires_at": "2026-09-03T00:00:00Z",
  "issuer": {
    "issuer_id": "shadow-network-admin",
    "signing_key_id": "admin-signing-key-1",
    "signature_algorithm": "ed25519"
  },
  "approved_devices": [
    {
      "device_id": "local-device-ab12cd34",
      "owner_name": "Responder One",
      "role": "responder",
      "status": "approved",
      "key_id": "device-key-2026-001",
      "key_version": 1,
      "key_algorithm": "x25519",
      "public_key": "base64url-public-key",
      "updated_at": "2026-08-03T00:00:00Z"
    }
  ],
  "revoked_devices": [],
  "signature": "base64url-ed25519-signature"
}
```

Bundle rules:

- Sign a documented canonical JSON representation that excludes the `signature` field itself.
- Verify issuer key, signature, schema version, bundle version, and expiry before import.
- Replace local trust state atomically only after full validation.
- Keep the last valid bundle when import fails.
- Reject rollback to an older bundle version outside explicit development testing.
- A trust-bundle public key verifies administrative signatures; it must not be the same key used for message decryption.

## Trust Classification Contract

Trust status is separate from spam moderation.

| Trust state | Normal feed | Map | Target recipient | Default relay policy |
|---|---|---|---|---|
| Approved | Show as verified | Allowed if non-spam | Allowed with valid key | Relay |
| Unknown | Show as unverified | Allowed only according to final safety policy | Not selectable for encrypted target | Relay |
| Revoked | Quarantine for audit | Exclude | Never selectable | Do not relay automatically |

The implemented capstone policy retains revoked-origin payloads for audit but excludes them from automatic relay and normal emergency presentation. Unknown-origin payloads remain relayable and visible as Unverified so lack of prior registration does not suppress an emergency report.

## Phase 2 Decision Record

- Selected canonical JSON with Ed25519 signatures for administrator-issued Version 2 trust bundles.
- Added monotonically increasing bundle versions, 30-day expiry, issuer ID, signing-key ID, and bundle hash metadata.
- The first valid administrator key is pinned on the phone after explicit user confirmation; later bundles from another key are rejected.
- Older bundles and altered same-version bundles are rejected, and failed imports leave the last valid bundle active.
- Persisted approved, unknown, and revoked trust states in SQLite database Version 7.
- Approved recipients with valid X25519 keys are selectable for targeted encryption; missing keys prevent publication or sending.
- Revoked-origin messages are retained in Quarantine, excluded from normal feeds and maps, and not automatically relayed.
- Unknown-origin messages remain available with an Unverified label and continue through SCF.
- Bundle trust does not replace sender signatures. A payload currently carries a claimed sender device ID, so cryptographic sender impersonation resistance remains future work.

## Key Rotation and Recovery

- A device generates a new key pair when the private key is missing or intentionally rotated.
- The old public key remains associated with historical messages but is no longer used for new sends after revocation or expiry.
- The admin approves the replacement key and publishes a higher trust-bundle version.
- Devices import the new signed bundle before sending to the rotated key.
- There is no plaintext fallback when the correct recipient key is unavailable.

## Logging Rules

Never log:

- Private keys.
- Shared secrets or derived content keys.
- Decrypted targeted message bodies in transport logs.
- Full trust-bundle signing secrets.

Safe diagnostic logs may include:

- Message hash.
- Key ID and key version.
- Security suite identifier.
- Validation success or failure category.
- Transport, hop count, and timestamps.

## Phase 1 Decision Record

- Selected AES-256-GCM.
- Selected `cryptography` for X25519, HKDF-SHA-256, and AES-GCM.
- Selected `flutter_secure_storage` for platform-backed private-key persistence.
- Defined canonical additional authenticated data with mutable hop count excluded.
- Added SOS schema 4 and chat schema 2 fixtures and tamper tests.
- Defined key reset/rotation behavior and retained SOS v1-v3/chat v1 readers.
- Completed automated security regression checks; independent security review and physical-device adversarial testing remain recommended before operational deployment.

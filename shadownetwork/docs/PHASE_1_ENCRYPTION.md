# Phase 1 Message Encryption

Completed: 2026-08-03

## Implemented Suite

Targeted SOS schema 4 and chat schema 2 use:

- Ephemeral X25519 key agreement for every message.
- HKDF-SHA-256 with a Shadow Network protocol context.
- AES-256-GCM authenticated encryption.
- Random 96-bit nonce generation.
- Immutable message metadata as additional authenticated data.
- SHA-256 envelope hashes for SCF deduplication with mutable hop count normalized to zero.

The wire suite identifier is `x25519-hkdf-sha256-aes-256-gcm-v1` and its protocol version is `1`.

## Device Registration

1. On the Android phone, open the Trust Bundle screen and select **Show PC Registration QR**.
2. In the browser admin dashboard, select **Scan Phone QR with PC Camera**.
3. Allow browser camera access and point the PC camera at the QR displayed on the phone.
4. Confirm that Device ID and X25519 public key were filled automatically.
5. Enter the owner name, choose the role, and add the registration.
6. Approve the device and export the updated trust bundle.
7. Import that bundle on every phone that must send targeted messages.

The browser camera works when the admin is served from `localhost` or another secure browser context. Exact Device ID and public-key fields can still be entered manually when a PC camera is unavailable.

Only the public key is registered or exported. The private key remains in platform secure storage on its phone.

## Sending Rules

- Broadcast SOS remains plaintext because every receiving device must be able to display it.
- Targeted SOS and chat require an approved recipient record containing a valid public key.
- Missing keys stop the send and display an error. There is no plaintext fallback.
- Relay-only devices store and forward the encrypted envelope without decrypting it.
- Only the intended recipient key can decrypt the body.

## Key Reset and Rotation

Clearing application data removes the private key. The phone then generates a new identity key, and payloads encrypted to the old key cannot be recovered by the new key. Re-register the displayed public key, approve it, export a new trust bundle, and import the bundle on sending phones.

Do not clear app data during a normal upgrade. Package updates preserve the secure identity and SQLite data.

## Compatibility

- SOS schemas 1, 2, and 3 remain readable.
- Chat schema 1 remains readable.
- New production writers use SOS schema 4 and chat schema 2.
- The legacy `sn-sha256-stream-v1` SOS cipher is compatibility-only.

## Verification

- Secure identity generation and reload.
- Recipient encryption/decryption round trip.
- Non-recipient and rotated-key rejection.
- Ciphertext and authenticated-metadata tamper rejection.
- No plaintext body in targeted SOS or chat payload JSON.
- Relay hop updates preserve ciphertext and the stable envelope hash.
- Full suite: 57 tests passed.
- Static analysis: no issues found.
- Android debug APK build: passed.
- Browser admin web build using `lib/admin_web_main.dart`: passed.

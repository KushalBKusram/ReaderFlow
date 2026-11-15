# Nearby Sync design

How the prototype moves a finished episode from the Mac to a phone over the
local network. The implementation lives in `experiments/nearby-sync-native-prototype/`
(library and CLI) and `ios/` (the iPhone receiver). Results are in
`experiments/nearby-sync-spike/RESULTS.md`.

## Properties

- **Explicit, expiring pairing.** A QR code (valid two minutes) starts pairing,
  and both devices show an approval step. Discovery is never treated as
  authorization.
- **Per-device trust that can be revoked locally.** Revoking on either side
  stops transfers; a fresh QR pairing is then required.
- **Authenticated encryption** for every transfer after pairing (Curve25519 key
  agreement, HKDF, AES-GCM framing).
- **Content-addressed manifest and chunk validation.** An episode is sent as
  1 MiB chunks. The receiver validates each chunk, persists an acknowledgement
  after every chunk, and treats retries as idempotent.
- **Verify before exposure.** The whole-file SHA-256 must match before the file
  moves out of staging into the library, so a partial or corrupted file is
  never playable.
- **Minimal payload.** Only generated episode media and the metadata needed for
  playback cross the link.

## What must never enter the QR payload, discovery data, sync payload or logs

Raindrop OAuth credentials, article text, model files, and secure-store data.

## Recovery behavior (as exercised in the Simulator)

Interruptions and restarts resume from the persisted chunk count rather than
from zero; the partial file stays in staging; and a retry made during an outage
fails cleanly without losing progress.

## Not covered

The prototype's transport is a QR-resolved TCP endpoint on the local network.
Physical-device behavior, background and sleep behavior, and Android and
Windows receivers were not part of the prototype.

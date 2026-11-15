# Nearby Sync feasibility spike

## Purpose

Establish the smallest trustworthy baseline for ReaderFlow's private
desktop-to-phone media transfer. The final product must remain local-first: it
does not upload audio to a hosted library or rely on a public podcast feed.

This spike has two separate parts:

1. A transport-agnostic manifest and resume ledger in `transfer_ledger.py`. It
   specifies integrity, retry, and final-acknowledgement behaviour without
   claiming to be a secure network transport.
2. A platform prototype to validate pairing, authenticated encryption, local
   network behaviour, and actual iPhone/Android delivery. It has not yet run.

## What the baseline proves

Run from the repository root:

```sh
PYTHONPATH=experiments/nearby-sync-spike \
python3 -m unittest discover -s experiments/nearby-sync-spike/tests -v
```

The tests prove that a receiver can agree an immutable, content-addressed
episode manifest; reject a corrupted chunk; persist acknowledgements and request
only missing chunks after interruption; safely retry an acknowledged chunk; and
complete only after whole-file size and SHA-256 verification.

They do **not** prove discovery, encryption, authentication, mobile storage
safety, or network performance. Those claims require the platform prototype.

## Proposed pairing and transfer contract

The product implementation must validate this contract with native,
platform-supported cryptography and networking APIs:

1. The desktop explicitly starts a short-lived pairing session. Its QR code
   contains only a session locator, expiry, one-time pairing secret, and desktop
   ephemeral public key—never a Raindrop token, source text, or media.
2. The phone shows the desktop identity and requested relationship. Both sides
   require explicit approval before persisting a device trust record.
3. The peers authenticate the pairing secret and exchange/pin device public
   keys. All later traffic uses authenticated encryption; discovery is not
   authorization.
4. The sender offers an episode manifest. The receiver uses app-private staging
   storage and a ledger, requests missing chunks, and verifies the final digest
   before exposing the episode in its library.
5. Either device can revoke a paired peer; a revoked peer must pair again.

The discovery transport is deliberately undecided until it passes the mobile
matrix. The security and retry contract is mandatory whichever transport wins.

## Desktop-to-desktop rehearsal

Before investing in native mobile clients, run this manual rehearsal between two
machines on the same ordinary home Wi-Fi:

1. Create a non-sensitive test audio file at least 250 MB and its manifest.
2. Pair with an expiring QR session and explicit approval on both machines.
3. Transfer it, interrupt Wi-Fi twice at different progress points, restart both
   processes once, and resume without duplicate library entries.
4. Compare the final SHA-256 digest, revoke the peer, and confirm it cannot
   reconnect without new QR pairing.
5. Record timing, failures, recovery, logs, and packet-security evidence in
   `MATRIX.template.md`; do not record pairing secrets or tokens.

The application prototype must use an authenticated encrypted channel. The
ledger alone is insufficient and must not be exposed as a user feature.

## Privacy constraints

- Transfer only generated episode media and non-sensitive playback metadata.
- Never transfer Raindrop OAuth tokens, source text, desktop secure-store data,
  model artifacts, or logs.
- Pairing is opt-in, visible, and revocable from both apps.
- Keep staging media and resume state out of source control.

See `RESULTS.md` for the results and `MATRIX.template.md` for required
cross-platform evidence.

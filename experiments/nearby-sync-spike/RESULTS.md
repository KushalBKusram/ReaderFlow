# Nearby Sync results

**Status:** concluded at Simulator-level evidence (2026-11-14). The prototype
verified pairing, authenticated encryption, resumable verified transfer and
revocation on a native macOS loopback, in a two-process rehearsal, and between
a Mac and the iPhone receiver running in the iOS 27.2 Simulator (see the
Simulator evidence section below). Physical-device, Android and Windows
verification were outside the scope of the prototype.

## Summary

**Conclusion for the prototype:** The
transport-agnostic ledger and the native loopback rehearsal establish retry,
integrity, authenticated encryption, and QR-session foundations. The committed
native CLI now provides separate two-Mac pairing, serving, receiver-ledger
resume, digest-before-exposure, and revocation workflows. Neither establishes
ordinary-Wi-Fi, two-Mac, iPhone, Android, or Windows reliability until a
physical matrix run is recorded.

## Evidence recorded

- `transfer_ledger.py` and its tests define a content-addressed manifest,
  idempotent retry acknowledgement, persisted resume state, and final digest
  verification.
- `MATRIX.template.md` defines the required Mac/Windows to iPhone/Android
  evidence.
- `../nearby-sync-native-prototype/` provides the macOS-native foundation:
  expiring, one-time QR pairing data; an approval-gated Curve25519/HKDF key;
  `Network` TCP framing; CryptoKit AES-GCM; persisted manifest/ledger resume;
  and trust-record revocation.
- Ignored local evidence at
  `.readerflow-nearby-sync/2026-08-05-engineer3-native-loopback/` records a
  successful non-sensitive 250 MiB loopback transfer. It deliberately stopped
  and recreated the listener twice, reloaded a persistent ledger once, and
  verified SHA-256 `e9e801cd063eaaaa11a4d79aae2d745b1e811a87e4394ab4590800d114e7de39`.
  This is a same-host rehearsal, not an ordinary-Wi-Fi or two-process result.
- The native README documents a physical two-Mac command sequence that keeps QR
  secrets/private keys out of command output and asks for explicit approval on
  both Macs. At this commit it is **not yet physical-run evidence**.

- iPhone receiver tooling now exists (`ios/` Sync tab, runbook in the native README); the physical Mac-to-iPhone run is still pending, so this is not mobile evidence.

## Not covered by the prototype (evidence a production gate would require)

1. A successful repeatable two-Mac rehearsal on ordinary home Wi-Fi,
   including two interruptions and a restart.
2. Matrix runs for every supported desktop/mobile pairing, covering integrity,
   interruption recovery, and revoke/re-pair behaviour.
3. A security review confirming OAuth tokens, source text, and media are absent
   from discovery, QR data, logs, and the sync payload.
4. A storage/recovery review confirming incomplete media never becomes playable
   and retries do not create duplicate library entries.

## Scope note

The original plan treated these items as a production gate. The prototype was
concluded without them: a physical-device run and the Android and Windows
matrix were outside its scope, so none of the results here should be read as
mobile-hardware evidence. A Simulator or desktop pass is not a substitute for a
physical iPhone pass.

## Simulator evidence (2026-11-14) — NOT a physical-device result

One Mac as sender (LAN address, not localhost) and the iPhone receiver in the
iOS 27.2 Simulator, through a throttling/outage proxy. The Simulator shares the
Mac's network stack, so this does not exercise iOS Local Network permission,
Wi-Fi client isolation, sleep, or real radio loss. Physical-device
behavior was not part of the prototype.

- Pairing: QR text pasted (no camera in Simulator); phone approved; approval
  entered on the Mac. Pairing request carried no secret.
- Clean transfer, 250 MiB: passed in-app SHA-256 check; Mac and phone digests
  matched; `Staging/` empty afterwards.
- Two outages (proxy cut + 8 s refusal) at ~25% and ~64%: phone showed 61 then
  161 of 250 chunks saved; resumed from the saved count each time; a retry made
  during the outage was refused and kept progress; digests matched.
- Restart: app force-quit and sender/proxy stopped at 57 of 250 chunks; relaunch
  showed 57 (persisted ledger also held 57); partial stayed in `Staging/`, never
  in `Episodes/`.
- Restart, completed: after the Simulator itself was rebooted, the app still
  showed 57 of 250; resuming against the restarted sender finished the file;
  Mac and phone digests matched and `Staging/` was empty. The Mac sender was
  restarted together with the app force-quit; a Mac-only restart was not run
  separately.
- Revoke: revoking on the phone removed the sender from the app; on the Mac,
  `revoke` then `serve` was refused ("This peer was revoked and must pair
  again"). Previously received, verified files were kept. A fresh re-pair after
  revoke was not exercised.

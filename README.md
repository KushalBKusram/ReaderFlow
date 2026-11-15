# ReaderFlow

> **A finished prototype (November 2026).** ReaderFlow turns a Raindrop reading
> queue into private, locally generated two-host podcasts on a Mac, with a tested
> design for encrypted nearby sync to a phone. This repository is the completed
> artifact and its write-up.
>
> **Read the write-up: [docs/index.html](docs/index.html)** (built for GitHub
> Pages) · technical notes: [docs/findings.md](docs/findings.md)

## What it is

- **Mac app (`macos/`)** — SwiftUI. Extracts text from a public URL, writes a
  two-host script with a local Qwen3 model (MLX), narrates it with Kokoro, and
  keeps a local episode library with resume, seek and speed. Fully local after a
  one-time model download. 26 unit tests. A packaged v0.4.0 build (ad-hoc signed, not
  notarized) is attached to the GitHub release.
- **Raindrop OAuth** — a client and a small relay design (`relay/`). Verified
  against a real registered app in a single-user "personal mode" (the user's
  own client secret in the Keychain).
- **Nearby Sync (`experiments/`, `ios/`)** — QR pairing, authenticated
  encryption, 1 MiB chunked resumable transfer with a persisted ledger,
  whole-file SHA-256 verification, and revocation, with an iPhone receiver.
  Verified end to end in the iOS 27.2 Simulator.

## What was verified, and its scope

| Area | Verified | Scope |
|---|---|---|
| Local generation | End to end on a Mac, packaged and used | Mac only; Windows not part of the prototype |
| Raindrop OAuth | Authorization, token storage, collections, persistence across relaunch | Single-user personal mode; relay written but not deployed; refresh-after-expiry not exercised |
| Nearby Sync | Pairing, encrypted transfer, resume after forced outages and a restart, digest verification, revoke | iOS Simulator (shares the Mac's network); not a physical-device or Android/Windows result |

Details: [RESULTS.md](experiments/nearby-sync-spike/RESULTS.md) and
[docs/findings.md](docs/findings.md).

## Repository layout

```
docs/          Write-up (index.html), findings, sync design, product/architecture notes
macos/         The Mac app (SwiftUI + MLX + Kokoro)
ios/           iPhone app: an on-device generation spike and the Nearby Sync receiver
relay/         Minimal Raindrop OAuth token relay design
experiments/   Feasibility prototypes, results, and Simulator rehearsal tools
```

## Building

Apple Silicon, macOS 14+, full Xcode. Open `macos/ReaderFlowMac.xcodeproj`,
scheme **ReaderFlow**. On Xcode 27.x the MLX macro package may fail with
"Unable to resolve Swift module dependency … SwiftSyntax"; see
[docs/findings.md](docs/findings.md).
Tests: `cd macos && swift test`. The Simulator sync rehearsal is described in
[experiments/nearby-sync-native-prototype/README.md](experiments/nearby-sync-native-prototype/README.md).

## Status and licensing

Final snapshot: tag `prototype-final-2026-11-14`. There is **no license file** —
all rights reserved until one is added. Model and voice weights are downloaded
by the app and are not included here.

# Native Nearby Sync prototype

The library builds for macOS 14+ and iOS 17+; the CLI is macOS-only. This is a rehearsal implementation for the contract in
`docs/nearby-sync-design.md`. It is intentionally separate
from the legacy web app and is not a production client.

It uses the macOS `Network` framework for the local TCP transport and
`CryptoKit` for Curve25519 key agreement and AES-GCM authenticated encryption.
The Swift `EpisodeManifest` and `TransferLedger` mirror the committed Python
baseline's JSON keys and semantics: content-addressed manifest, chunk digests,
persisted acknowledgement ledger, idempotent retries, and final SHA-256 check.

## Verify

```sh
swift build --package-path experiments/nearby-sync-native-prototype
swift run --package-path experiments/nearby-sync-native-prototype \
  readerflow-nearby-sync-native self-test .readerflow-nearby-sync/<dated-run>
```

`self-test` is a same-host loopback check. It creates non-sensitive generated
bytes, transfers them through the encrypted local listener, persists two
interruption checkpoints and one restart checkpoint, checks the final digest,
and proves trust-store revocation removes the peer. It is not a substitute for
two physical Macs or the mobile matrix.

## Required physical-Mac rehearsal

Run this only with two physical Macs on ordinary local Wi-Fi. The CLI does not
accept loopback as evidence. It communicates one fresh QR payload by scanning;
the payload is never printed or written to a matrix note. The receiver returns
a public-key-only pairing request, which may be copied to the sender.

Use a dated, ignored run directory on each Mac, for example
`.readerflow-nearby-sync/2026-08-05-engineer3-two-mac/`. Keep its QR image,
trust records, pairing request, test media, staging file, and ledger local.
None of them belong in Git or an evidence note.

1. On the sender, choose its current Wi-Fi IPv4 address and a free port, create
   a non-sensitive 250 MiB file, then start pairing. The sender pauses for the
   receiver's public pairing request; its QR expires after 120 seconds.

   ```sh
   swift run --package-path experiments/nearby-sync-native-prototype \
     readerflow-nearby-sync-native sender-pair \
     .readerflow-nearby-sync/<date>-engineer3-two-mac/sender \
     <sender-wifi-ip>:8443 \
     .readerflow-nearby-sync/<date>-engineer3-two-mac/sender/pairing.png
   ```

2. On the receiver, scan the QR and pipe the scanner's URI directly to
   `receiver-pair`; explicitly type `approve` after verifying the endpoint.
   Copy only its standard-output JSON back to the waiting sender, which also
   requires a human to type `approve`. The receiver prints a non-secret sender
   peer ID to standard error; retain that ID for subsequent commands.

   ```sh
   <qr-scanner-command> | swift run --package-path experiments/nearby-sync-native-prototype \
     readerflow-nearby-sync-native receiver-pair \
     .readerflow-nearby-sync/<date>-engineer3-two-mac/receiver receiver-mac
   ```

3. Start the sender, using `receiver-mac` as the approved receiver ID. Then
   pull on the receiver, using the printed sender peer ID. `receive` persists
   `ledger.json` after each acknowledged chunk and only moves the completed
   staging file into its final name after whole-file SHA-256 verification.

   ```sh
   # Sender
   swift run --package-path experiments/nearby-sync-native-prototype \
     readerflow-nearby-sync-native serve <sender-trust-dir> receiver-mac \
     <non-sensitive-250MiB-file> 8443

   # Receiver
   swift run --package-path experiments/nearby-sync-native-prototype \
     readerflow-nearby-sync-native receive <receiver-trust-dir> <sender-peer-id> \
     <sender-wifi-ip> 8443 <receiver-staging-dir>
   ```

4. Disable Wi-Fi or otherwise break the local network twice at materially
   different transfer points, relaunch `serve`, and re-run `receive`. Restart
   both CLI processes once between those recoveries. The receiver must resume
   only missing chunks from its persisted ledger.
5. Record the final digest shown by `shasum -a 256 <received-final-file>` but
   never the media filename or contents. Revoke the peer on both Macs, prove a
   new `serve`/`receive` cannot start from the removed trust record, and then
   complete a fresh QR pairing before attempting another transfer.

   ```sh
   readerflow-nearby-sync-native revoke <sender-trust-dir> receiver-mac
   readerflow-nearby-sync-native revoke <receiver-trust-dir> <sender-peer-id>
   ```

Copy `../nearby-sync-spike/MATRIX.template.md` to the dated directory as
`MATRIX.md`. Include only device/OS, build commit, size, pairing expiry and
approval result, interruption/restart recovery, digest, revoke/re-pair result,
timings, and concise failures. Do not record pairing secrets, QR payloads,
private keys, source text, OAuth tokens, media contents, or model data.

## Mac-to-iPhone rehearsal (one Mac, one iPhone)

Tooling exists; **no physical run has been recorded**. The iPhone receiver is
the **Sync** tab of `ios/ReaderFlowiOS.xcodeproj`. It reuses the library's QR
pairing, Curve25519/HKDF key, AES-GCM framing and `TransferLedger`
(`Sources/NearbySyncNative/Receiver.swift`). It verifies each chunk before
writing it, persists the ledger after every chunk, and moves the file out of
staging only after the whole-file SHA-256 passes.

### 0. Prerequisites

- iPhone on iOS 17+ with Developer Mode on, on the **same ordinary Wi-Fi** as
  the Mac (not guest/isolated Wi-Fi, no VPN).
- Xcode, with your own Apple ID or team under Xcode > Settings > Accounts.
- Run all Mac commands from the repo root. A dated, git-ignored run directory
  keeps trust records, QR image and media local:

  ```sh
  RUN=.readerflow-nearby-sync/$(date +%F)-iphone
  mkdir -p $RUN/sender
  MAC_IP=$(ipconfig getifaddr en0)   # use the Wi-Fi interface; check it is not empty
  PORT=8443
  CLI="swift run --package-path experiments/nearby-sync-native-prototype readerflow-nearby-sync-native"
  ```

- Create a non-sensitive 250 MiB file (any content you don't mind; do not use
  real articles):

  ```sh
  head -c 262144000 /dev/urandom > $RUN/test-250mb.m4a
  ```

### 1. Build and install the iPhone app

1. `open ios/ReaderFlowiOS.xcodeproj`.
2. Select the `ReaderFlowiOS` target > Signing & Capabilities. Pick **your**
   team. (`DEVELOPMENT_TEAM` is blank in git; do not commit the change.) If the
   bundle ID `com.readerflow.ios` is taken for your team, change it locally.
3. Choose your iPhone as the run destination and Run. Trust the developer
   profile on the phone if prompted (Settings > General > VPN & Device
   Management). Open the **Sync** tab.
4. For a CLI build check without a device:
   `xcodebuild -project ios/ReaderFlowiOS.xcodeproj -scheme ReaderFlowiOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`.
   The Simulator has no camera; use "paste QR text" there.

### 2. Pair (120-second window: read all of this first)

1. On the Mac: `$CLI sender-pair $RUN/sender $MAC_IP:$PORT $RUN/sender/pairing.png`
   then `open $RUN/sender/pairing.png`.
2. On the iPhone, Sync tab: leave the ID as `iphone-receiver` (or choose one),
   tap **Scan pairing QR**, scan the Mac screen. The phone shows the endpoint.
   Check it is your Mac's address, then tap **Approve and trust this Mac**. The
   first camera use prompts for camera access (used only for this scan).
3. The phone shows a public pairing request JSON. Tap **Copy request**.
   Paste it into the waiting Mac terminal (Universal Clipboard, or send it to
   yourself in Messages/Notes), press Return, then Control-D. Type `approve`
   at the Mac's prompt. It contains no secret.
4. If the 120 seconds lapse, the phone already trusts a sender the Mac never
   approved: tap **Revoke this Mac** on the phone and start over.
5. The phone lists the sender peer ID (`sender-…`, not secret). Record that you
   saw it; you do not need to type it anywhere.

### 3. Transfer

1. Mac: `$CLI serve $RUN/sender iphone-receiver $RUN/test-250mb.m4a $PORT`
   (the second argument must equal the phone's ID).
2. iPhone: confirm the IP/port fields, tap **Receive from this Mac**. Allow
   **Local Network** when iOS asks. If the first attempt times out while the
   prompt was up, tap Receive again. Keep the screen on (the app disables
   auto-lock while receiving).
3. On success the phone shows "passed SHA-256 verification" and lists the file
   under Received.

### 4. Interruption and restart (do both)

- **Interruption x2:** during a transfer, at two clearly different progress
  points (e.g. ~25% and ~65%), break the path: turn the phone's Wi-Fi off for
  ~10 s, or stop `serve` with Control-C. The phone shows an error and "N of M
  chunks saved". Restore Wi-Fi / rerun the `serve` command, tap **Receive**. Only
  missing chunks should be fetched (progress resumes from N, not 0).
- **Restart once:** mid-transfer, force-quit the app and Control-C `serve`;
  relaunch both, check the saved chunk count is shown on the Sync tab, then
  Receive. Also do one Mac-side restart on its own.
- Note the chunk counts before and after each recovery.

### 5. Verify and revoke

1. Compare digests. Mac: `shasum -a 256 $RUN/test-250mb.m4a`. iPhone: Xcode >
   Window > Devices and Simulators > your iPhone > ReaderFlowiOS > ... >
   Download Container; inspect `AppData/Library/Application
   Support/NearbySync/Episodes/test-250mb.m4a` with `shasum -a 256`. The two
   digests must match. Check `Staging/` contains no `episode.partial`.
2. **Revoke:** tap **Revoke this Mac** on the phone; run
   `$CLI revoke $RUN/sender iphone-receiver` on the Mac. Confirm `serve` /
   Receive can no longer start (the phone lists no sender), then complete a
   fresh QR pairing before another transfer.

### 6. What to record

Copy `../nearby-sync-spike/MATRIX.template.md` to `$RUN/MATRIX.md` (ignored
by git). Record only: Mac model/macOS, iPhone model/iOS, build commit, size,
pairing time vs the 120 s expiry and approvals on both sides, the Local
Network prompt behaviour, interruption/restart recovery with chunk counts,
digests (both), revoke/re-pair result, timings, and concise failures. Never
record the QR payload/image, pairing request, trust files, media, or names.
The results in `experiments/nearby-sync-spike/RESULTS.md` are Simulator-level; a physical-device run would be a separate result.

### Known limitations of this prototype

- Trust records (including the channel key) live in a file in the app's
  Application Support folder, not the Keychain. Production must use secure
  storage.
- The transfer stops when iOS suspends the app (screen locked / backgrounded);
  it resumes from the ledger when you return and tap Receive.
- No Bonjour discovery: the endpoint comes from the QR (an IPv4 address).
- Sender revocation on the Mac and on the phone are separate manual steps.

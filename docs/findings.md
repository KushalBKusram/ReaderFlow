# Technical findings

Notes from building the ReaderFlow prototype. Each finding is stated with the
evidence it rests on.

## Raindrop requires a client secret, so distributed apps need a relay

Raindrop's token endpoint
(<https://developer.raindrop.io/v1/authentication/token>) requires
`client_secret` in both the authorization-code exchange and the refresh
request, and documents no PKCE alternative. A secret embedded in a distributed
desktop app can be extracted from the binary, so an app handed to other people
needs a small relay that holds the secret and proxies only those two calls.
`relay/` contains one (a Cloudflare Worker, about 70 lines, stores nothing). It
is a design and was not deployed.

For a single-user build the app has a **personal mode**: the user pastes their
own client secret, it is stored in the Keychain only, and tokens are exchanged
directly with Raindrop. This was verified against a real registered app:
browser authorization, token exchange, Keychain storage, collection listing,
and persistence across an app relaunch. Token refresh after expiry (about two
weeks) was not exercised.

Raindrop's app-registration form silently refuses to save unless Description
and Site are filled in as well as the redirect URI.

## Local generation

Qwen3 (script) plus Kokoro (two-host narration) runs fully on a Mac. Kokoro on
the CPU outperformed the GPU (MPS) path on real dialogue-shaped input, so CPU is
the default.

## Nearby Sync

The transfer protocol (expiring QR pairing, authenticated key agreement, 1 MiB
AES-GCM chunks, a persisted ledger, whole-file SHA-256 before exposure, and
revocation) was exercised between a Mac and an iPhone receiver in the iOS 27.2
Simulator, including forced network outages, an app force-quit and a Simulator
reboot. Results and caveats are in
`experiments/nearby-sync-spike/RESULTS.md`; the tooling is in
`experiments/nearby-sync-native-prototype/tools/`. A Simulator shares the host's
network stack, so these are not physical-device results.

Operational notes from the rehearsal: the receiver fetches one chunk per
connection, so interruption tests should cut by cumulative bytes rather than by
connection; and a scripted Simulator needs the on-screen keyboard forced on
(`simctl`/tool setting) for a stable layout when pasting.

## Toolchain notes

- **Xcode 27.2 / Swift 6.4:** the MLX macro dependency pins `swift-syntax` below
  604, and Xcode's prebuilt SwiftSyntax binary does not match this toolchain,
  producing "Unable to resolve Swift module dependency … SwiftSyntax". Setting
  `defaults write com.apple.dt.Xcode IDEPackageEnablePrebuilts NO` (then
  clearing DerivedData) builds it from source. The Metal toolchain must also be
  installed (`xcodebuild -downloadComponent MetalToolchain`).
- **Swift 6 concurrency:** the Xcode project builds with `SWIFT_VERSION = 5.0`,
  which hid a data-race diagnostic that `swift test` (Swift 6 mode) reported
  in the OAuth client; the class is now `@MainActor`.

# ReaderFlow for iOS

This directory contains the new native iPhone app. It is not the archived iOS
prototype in `_archive/ios`.

`ReaderFlowiOS/` is a SwiftUI feasibility spike for the local episode experience:
article input, script review, and playback. The iOS Foundation Models adapter is
explicitly optional and only enabled on compatible devices; it is not a claim
that the desktop-first generation, Kokoro packaging, or Nearby Sync gates are
complete.

Open `ReaderFlowiOS.xcodeproj` in Xcode, choose an iPhone running iOS 17 or
later, and run the `ReaderFlowiOS` scheme. On iOS 26+ with Apple Intelligence
available, the Studio screen can request an on-device script draft. Other
devices retain the listener UI and show a clear availability message.

## Nearby Sync receiver (rehearsal tooling)

The **Sync** tab (`ReaderFlowiOS/NearbySync/`) is a minimal receiver for the
Mac-to-iPhone Nearby Sync rehearsal. It links the `NearbySyncNative` package
from `experiments/nearby-sync-native-prototype/`. `DEVELOPMENT_TEAM` is blank:
choose your own signing team in Xcode (Signing & Capabilities). The step-by-step
runbook is in `experiments/nearby-sync-native-prototype/README.md`.

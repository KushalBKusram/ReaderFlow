# ReaderFlow for macOS

This is the home of the new native macOS desktop application. It is the current
implementation focus.

The initial alpha is a SwiftUI and AVFoundation app that stores and plays local
ReaderFlow episodes. Its complete first loop is:

```text
local source -> local generation -> local episode library -> Mac playback
```

The app must not depend on the legacy `webapp/` or `_archive/` clients. Keep
model/script generation, narration, episode storage, and playback behind
replaceable boundaries as defined in `docs/architecture.md`. Raindrop OAuth,
Nearby Sync, and Windows support are separate work streams.

## Build and run

Requirements: macOS 14 or later on Apple Silicon and the full Xcode app (not
Command Line Tools alone). The local Qwen runtime uses MLX and is therefore not
available on Intel Macs in this spike. Open `macos/ReaderFlowMac.xcodeproj` in
Xcode, select the
**ReaderFlow** scheme, choose **My Mac**, then press Run. This is a native
`.app` target; do not use `Package.swift` for normal interactive runs.

The first build resolves the official MLX Swift and Hugging Face Swift packages.
Xcode may ask you to enable their Swift macro/build-tool packages; review the
listed repositories and enable them to build this local-only runtime. Xcode 27
also needs its Metal Toolchain component installed.

Use **Create episode** to paste a public article URL (or article text). URL
fetching uses an ephemeral request with no cookies or credentials and does not
attempt to bypass a sign-in or paywall. The studio now offers a one-time local
AI asset setup: it fetches Qwen3 4B (4-bit) and Kokoro files into Application
Support, checks each published SHA-256 when one is available, and never needs
an API key. No sample article, script, or audio ships in the app.

The native Qwen inference and two-host Kokoro renderer are the active
feasibility spike. The UI does not fall back to Apple Foundation Models, cloud
generation, or a macOS system voice. The current Kokoro runner is an isolated
Python 3.12 runtime stored under `Application Support/ReaderFlow/Runtime`; it
is approximately 1.5 GB and is a Mac-prototype packaging bridge, not the
future shipping runtime. It renders `HOST_A` as `af_bella` and `HOST_B` as
`am_michael`, then stores a local WAV episode in the library.

The app currently uses Kokoro's CPU backend by default. The PyTorch Metal/MPS
path remains under evaluation in `experiments/kokoro-mps-spike`: it can be
faster on controlled inputs, but has produced macOS crash alerts for some real
article scripts. It must pass the documented compatibility gate before being
enabled for users.

Select a created episode in the sidebar to play it, seek, change speed, and
resume later. The player refreshes recovery state before it opens the file, so
missing or corrupt audio stays in the supplied safe recovery state. Playback
position is saved during playback, on pause, on completion, and whenever the
app backgrounds or quits.

## Headless generation

The same local generation core can run without creating a window. This is for
development and integration validation; it uses the installed local models and
writes the identical local-library artifacts as the UI. Build the app first,
then run the generated executable with a public URL:

```sh
/path/to/ReaderFlow.app/Contents/MacOS/ReaderFlow \
  --generate-url 'https://example.com/article' \
  --title 'Optional episode title' \
  --detail depth
```

It emits newline-delimited JSON stages (`extracting_article`,
`generating_script`, `rendering_audio`, and `saving_episode`) and finishes with
the stored audio path. The macOS studio calls the same draft and audio services;
it is not a separate implementation. No window, API key, browser cookie, or
cloud model is involved.

Choose `--detail brief`, `--detail depth` (the default), or `--detail detail`.
The same three choices appear in the studio. They calculate a target script size
from the readable article text: Brief is a focused overview, In depth aims for a
full explanation, and Detailed expands the discussion further. Each draft has a
second local Qwen editorial pass before it is shown or rendered.

QR-paired iPhone transfer is deliberately not implemented in this application
slice. The encrypted/resumable transport prototype is in
`experiments/nearby-sync-native-prototype`; it remains a feasibility gate until
the physical-device matrix passes.

For a command-line test run with full Xcode selected:

```sh
cd macos
swift test --filter EpisodeLibraryStoreTests
```

This requires the full Xcode developer directory to be selected. The Command
Line Tools installation on this machine cannot resolve `XCTest`, so it can
build the production targets but cannot run this test target. In that case,
verify compilation with `swift build`, then run the tests and a real-local-audio
playback check from Xcode on macOS 14 or later.

The durable library lives in `~/Library/Application Support/ReaderFlow/EpisodeLibrary`:
the JSON index is `episode-library.json`, and each episode exclusively owns
`episodes/<episode UUID>/`. Do not place unrelated files in an episode directory.

## Episode-library contract

`ReaderFlowEpisodeLibrary` is intentionally independent of SwiftUI, AVFoundation,
Qwen, Kokoro, Raindrop OAuth, and Nearby Sync. It exposes `Episode` and
`EpisodeLibraryStore` for the player and future providers.

An episode has a stable UUID; safe title/display metadata; creation date;
relative script, audio, and immutable-manifest paths; optional audio duration;
persistent playback position; lifecycle; and a user-safe recovery error. All
three paths must be under `episodes/<that episode UUID>/`. `upsert` writes a
complete record after a generator has written its artifacts. A player persists
resume via `updatePlaybackPosition(for:to:)` and calls
`refreshRecoveryState(for:)` before opening audio. It must present the supplied
recovery message rather than a system error. `delete(id:)` validates the paths,
deletes only the matching episode directory, then atomically updates the index.

The episode-library package deliberately knows nothing about generation, OAuth,
or sync. The app attaches the local Qwen/Kokoro generation boundary and
AVFoundation playback at its outer edge; future Nearby Sync providers must use
the same artifact contract.

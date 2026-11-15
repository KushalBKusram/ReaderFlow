# Target architecture

## System shape

```
Raindrop OAuth
  -> ReaderFlow Desktop
      -> article extraction
      -> local script model
      -> local voice model
      -> local episode library
      -> Nearby Sync over Wi-Fi
          -> ReaderFlow Mobile Listener
```

## Components

### ReaderFlow Desktop

The desktop app is the production surface. It owns Raindrop access, article
retrieval, local model execution, media generation, the episode library, and
paired-device transfer.

It must package the local model runtime so a user never has to install or learn
another AI tool. The current preferred script candidate is Qwen3 4B for the
first managed download, with a larger Qwen3 instruction model as an opt-in
quality tier; Kokoro two-host narration is the confirmed Mac-first choice,
rendered on CPU by default (it outperformed the GPU/MPS path on real
dialogue-shaped input; see `docs/findings.md`). Model and voice artifacts remain
replaceable until licensing, quality, performance, and packaging have passed
their feasibility work.

The generation pipeline must be modular:

- a versioned script-provider interface produces a reviewable cited script;
- a separate narration-provider interface consumes clean narration text and
  produces local audio;
- an artifact manifest records model/voice version, checksum, license,
  runtime, and generation settings for every episode;
- new model or voice releases are opt-in downloads with compatibility checks,
  rollback, and no change to existing episode playback.

This lets ReaderFlow improve script quality and voices over time without
migrating user content or coupling the desktop app to one engine.

### ReaderFlow Mobile

The mobile app is a private listener, not a server. It pairs once with a
desktop, receives episodes on the local network, stores them offline, and
provides basic playback.

### Minimal OAuth relay

Raindrop's OAuth flow requires a registered client secret. If the final desktop
flow cannot safely keep that secret out of the client, use a narrow relay only
for authorization-code exchange and token refresh. It must not persist article
content, scripts, audio, device-transfer data, or product analytics.

## Data ownership and boundaries

| Data | Default location | Rule |
| --- | --- | --- |
| Raindrop OAuth tokens | Desktop OS secure storage | Never log or sync to mobile. |
| Article text | Desktop working storage | Delete after configured retention; never send to an optional relay. |
| Script and audio | Desktop library, then paired phone | Transfer only after authenticated pairing. |
| Models and voices | Desktop model cache | Keep version and license manifest. |
| Product feedback | Opt-in local log by default | Implemented on Mac (off until the user turns it on); do not collect article contents. |

## Nearby Sync requirements

- Pair through an explicit QR-code flow.
- Authenticate both peers and encrypt every transfer.
- Prefer local Wi-Fi for media; use Bluetooth only if needed for discovery or
  pairing metadata.
- Support resumable transfer, duplicate detection, explicit retry, revocation,
  and safe behavior when an app sleeps or changes networks.
- The v1 contract is foreground nearby sync. Automatic remote delivery is a
  later product decision.

## Non-goals for the architecture

Do not design a public media server, an RSS publishing service, an always-on
desktop agent, or a cloud media store for v1.

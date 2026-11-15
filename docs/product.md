# Product direction

## Positioning

> **ReaderFlow turns a user's Raindrop reading queue into private, locally
> generated podcasts that sync directly from their computer to their phone.**

ReaderFlow is for normal Raindrop users with a Mac or Windows computer and an
iPhone or Android phone. The computer is a studio, not a server: it only needs
to be awake while it fetches, creates, or transfers an episode.

## Core job

When a user saves an article they want to understand but are unlikely to read
soon, ReaderFlow makes it available as an offline listening episode.

## V1 promise

Install ReaderFlow, connect Raindrop once, download local AI once, create an
episode, and listen to it on a paired phone.

## Mac-first alpha

The immediate product milestone is a Mac app that creates and plays a local
episode on the Mac. It is a deliberately smaller proof of the core experience:
the user selects a source, ReaderFlow generates local audio, stores the
episode with its manifest, and offers dependable desktop playback.

This alpha does not require a phone, Nearby Sync, Windows support, or a
finished Raindrop connection. Those remain required before the broader v1
promise is made. The Mac alpha must use the same replaceable local
script-provider, narration-provider, and episode-library boundaries that the
eventual desktop product will use.

## In scope

- Raindrop OAuth connection and a bookmark inbox.
- Reliable extraction for ordinary public articles.
- Local, source-grounded script generation.
- Local narration and an on-device episode library.
- Mac desktop playback for locally generated episodes: play/pause, seek,
  speed, resume position, delete, and clear generation/playback failures.
- QR pairing and encrypted nearby Wi-Fi transfer.
- ReaderFlow mobile listener for iPhone and Android.
- Basic playback, deletion, download, seek, speed, and resume.
- Clear hardware, storage, model-download, and failure messaging.

## Explicitly out of scope

- NotebookLM, Google cookie export, and cloud-only generation.
- Docker, self-hosted server administration, Tailscale, and RSS as the default
  delivery path.
- Third-party podcast-app integration, remote sync, multi-user sharing, and
  scheduled/bulk generation.
- Voice cloning, research discovery, Q&A, and word-level transcript sync.

Two-host conversational episodes are in scope for the Mac-first alpha when
they are rendered with licensed, non-cloned local voices. They remain subject
to the local-generation quality and packaging gate.

## Product success

The central proof is repeat listening, not generation novelty. Measure episode
creation, starts, completions, weekly listening days, saved-link conversion,
generation/extraction failures, and reasons users return or abandon the tool.

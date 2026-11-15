import AVFoundation
import Foundation
import Observation
#if !READERFLOW_APP
import ReaderFlowEpisodeLibrary
#endif

public enum EpisodePlayerState: Equatable, Sendable {
    case idle
    case ready
    case playing
    case unavailable(String)
}

public enum EpisodePlaybackMetricEvent: Sendable, Equatable {
    case started
    case completed
}

/// AVFoundation playback adapter for a single library episode. It consumes only the episode-library contract.
@MainActor
@Observable
public final class EpisodePlayer: NSObject, AVAudioPlayerDelegate {
    public private(set) var state: EpisodePlayerState = .idle
    public private(set) var episodeID: UUID?
    public private(set) var elapsed: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var playbackRate: Float = 1
    /// Lets a caller observe playback lifecycle without this module knowing
    /// anything about metrics, settings, or storage — the same closure-based
    /// decoupling the generation pipeline already uses for progress.
    public var onPlaybackEvent: (@Sendable (EpisodePlaybackMetricEvent) -> Void)?

    private let store: EpisodeLibraryStore
    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: Timer?
    private var progressTickCount = 0
    private var pendingPositionSave: Task<Void, Never>?

    public init(store: EpisodeLibraryStore) {
        self.store = store
        super.init()
    }

    public var isPlaying: Bool {
        if case .playing = state { return true }
        return false
    }

    public func play(_ episode: Episode) async {
        if episodeID != episode.id || audioPlayer == nil {
            await prepare(episode)
        }
        guard let audioPlayer, case .ready = state else { return }
        audioPlayer.enableRate = true
        audioPlayer.rate = playbackRate
        guard audioPlayer.play() else {
            state = .unavailable(EpisodeRecoveryError.audioUnreadable.message)
            return
        }
        state = .playing
        startProgressTimer()
    }

    public func pause() async {
        guard let audioPlayer else { return }
        audioPlayer.pause()
        syncProgress()
        await persistCurrentPosition()
        state = .ready
        stopProgressTimer()
    }

    public func seek(to position: TimeInterval) async {
        guard let audioPlayer else { return }
        let safePosition = min(max(0, position), duration)
        audioPlayer.currentTime = safePosition
        elapsed = safePosition
        schedulePositionSave()
    }

    /// Dragging the scrubber emits a continuous stream of seeks, and every
    /// persist re-encodes and rewrites the entire library index. Collapse a
    /// drag into a single write once it settles. Pause, finish, and app
    /// backgrounding still persist immediately.
    private func schedulePositionSave() {
        pendingPositionSave?.cancel()
        pendingPositionSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await self?.persistCurrentPosition()
        }
    }

    /// Moves relative to the current position while preserving the same bounds
    /// and persistence behavior as a direct scrub.
    public func skip(by interval: TimeInterval) async {
        await seek(to: elapsed + interval)
    }

    public func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        audioPlayer?.enableRate = true
        audioPlayer?.rate = rate
    }

    /// Stops playback and releases the audio without writing a position back.
    /// Used when the episode itself is going away: there is no library row
    /// left to persist to, and leaving `AVAudioPlayer` alive would keep
    /// playing audio the user can no longer see or control.
    public func stopAndUnload() {
        // Drop any debounced write first: the episode is going away, and a
        // late save would target a row that no longer exists.
        pendingPositionSave?.cancel()
        pendingPositionSave = nil
        stopProgressTimer()
        audioPlayer?.stop()
        audioPlayer = nil
        episodeID = nil
        elapsed = 0
        duration = 0
        state = .idle
    }

    public func persistCurrentPosition() async {
        pendingPositionSave?.cancel()
        pendingPositionSave = nil
        guard let id = episodeID else { return }
        syncProgress()
        // A failed position write is a bookkeeping problem, not a playback
        // one — the audio is still loaded and fine. Marking the player
        // unavailable here would disable every transport control while the
        // episode keeps playing.
        try? await store.updatePlaybackPosition(for: id, to: elapsed)
    }

    /// `AVAudioPlayerDelegate` is not main-actor isolated, so satisfying it
    /// from a `@MainActor` type requires this callback to be `nonisolated`
    /// and hop explicitly. Without it the whole module fails to build under
    /// strict concurrency checking.
    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard flag else { return }
        // Carry only the player's identity across the hop: AVAudioPlayer is
        // not Sendable, so passing the object itself would trade this error
        // for a data-race one.
        let finished = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let current = self.audioPlayer, ObjectIdentifier(current) == finished else { return }
            self.finishPlayback()
        }
    }

    func finishPlayback() {
        pendingPositionSave?.cancel()
        pendingPositionSave = nil
        elapsed = 0
        audioPlayer?.currentTime = 0
        state = .ready
        stopProgressTimer()
        onPlaybackEvent?(.completed)
        Task { [store, episodeID] in
            guard let episodeID else { return }
            try? await store.updatePlaybackPosition(for: episodeID, to: 0)
        }
    }

    private func prepare(_ episode: Episode) async {
        await persistCurrentPosition()
        stopProgressTimer()
        audioPlayer = nil
        episodeID = nil
        do {
            let refreshed = try await store.refreshRecoveryState(for: episode.id)
            guard refreshed.lifecycle == .ready else {
                state = .unavailable(refreshed.recoveryError?.message ?? EpisodeRecoveryError.audioUnreadable.message)
                return
            }
            let url = try await store.audioURL(for: episode.id)
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.enableRate = true
            player.rate = playbackRate
            duration = player.duration
            let resume = refreshed.playbackPosition < duration ? refreshed.playbackPosition : 0
            player.currentTime = resume
            elapsed = resume
            if resume != refreshed.playbackPosition { try await store.updatePlaybackPosition(for: episode.id, to: 0) }
            audioPlayer = player
            episodeID = episode.id
            state = .ready
            // Fires once per episode load, not per resume-from-pause, so it
            // reads as "an episode was started" rather than "play was tapped".
            onPlaybackEvent?(.started)
        } catch {
            state = .unavailable(EpisodeRecoveryError.audioUnreadable.message)
        }
    }

    private func syncProgress() {
        guard let audioPlayer else { return }
        elapsed = audioPlayer.currentTime
        duration = audioPlayer.duration
    }

    private func startProgressTimer() {
        stopProgressTimer()
        progressTickCount = 0
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.syncProgress()
                self.progressTickCount += 1
                // Persisting rewrites the whole library index, so it would be
                // wasteful to do it every second purely to track playback
                // position. Pause/seek/finish/backgrounding already persist
                // immediately; this periodic write is only a crash safety net.
                guard self.progressTickCount.isMultiple(of: Self.persistenceIntervalSeconds) else { return }
                await self.persistCurrentPosition()
            }
        }
    }

    private static let persistenceIntervalSeconds = 10

    private func stopProgressTimer() { progressTimer?.invalidate(); progressTimer = nil }
}

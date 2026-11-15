import AppKit
import Foundation
import Observation
#if !READERFLOW_APP
import ReaderFlowAudioPlayback
import ReaderFlowEpisodeLibrary
#endif

/// A render running after the studio sheet has already closed. The main
/// library view surfaces this instead of blocking the sheet on the slow,
/// no-further-input-needed audio synthesis step.
struct PendingRender: Identifiable {
    let id = UUID()
    var title: String
    var stage: EpisodeGenerationStage
}

@MainActor
@Observable
final class LibraryViewModel {
    private(set) var episodes: [Episode] = []
    private(set) var loadError: String?
    private(set) var player: EpisodePlayer?
    private var store: EpisodeLibraryStore?
    var sourceText = ""
    var draftScript = ""
    var studioTitle = ""
    var detailLevel: EpisodeDetailLevel = .depth
    var contentStyle: EpisodeContentStyle = .conversational
    private(set) var isGenerating = false
    private(set) var isImportingPDF = false
    private(set) var pendingRender: PendingRender?
    private(set) var studioMessage: String?
    let localAI = LocalAISetup()
    private var metricsLog: DogfoodMetricsLog?

    static let untitledPlaceholder = "New local episode"

    init() { Task { await load(); localAI.refresh() } }

    func load() async {
        metricsLog = (try? DogfoodMetricsLog.defaultLogURL()).flatMap { try? DogfoodMetricsLog(logURL: $0) }
        do {
            let root = try EpisodeLibraryStore.defaultRootURL()
            let store = try EpisodeLibraryStore(rootURL: root)
            self.store = store
            let player = EpisodePlayer(store: store)
            player.onPlaybackEvent = { [weak self] event in
                Task { @MainActor in self?.recordPlayback(event) }
            }
            self.player = player
            episodes = try await store.refreshRecoveryStateForAllEpisodes()
        } catch {
            loadError = "Your local episode library could not be opened. Restart ReaderFlow or check available storage."
        }
    }

    private func recordPlayback(_ event: EpisodePlaybackMetricEvent) {
        let metricEvent: DogfoodMetricEvent = event == .started ? .playbackStarted : .playbackCompleted
        Task { await metricsLog?.record(metricEvent) }
    }

    /// The count of locally logged dogfood events, for the privacy sheet —
    /// so turning this on is never a black box.
    func metricsEventCount() async -> Int { await metricsLog?.allRecords().count ?? 0 }

    func clearMetricsLog() async { await metricsLog?.clear() }

    func persistPlaybackPosition() async { await player?.persistCurrentPosition(); episodes = await store?.allEpisodes() ?? [] }

    func scriptText(for episode: Episode) async -> String? {
        try? await store?.scriptText(for: episode.id)
    }

    func delete(_ episode: Episode) async {
        do {
            // Unload before the row disappears. Otherwise the audio keeps
            // playing with no visible transport to stop it, and the next
            // position write fails against an episode that no longer exists.
            if player?.episodeID == episode.id { player?.stopAndUnload() }
            try await store?.delete(id: episode.id)
            episodes = await store?.allEpisodes() ?? []
            // An episode removed without ever finishing playback is a
            // dogfood abandonment signal; one removed after a full listen
            // is just library cleanup, not abandonment.
            let reason = episode.playbackPosition > 0 ? "afterPartialListen" : "unplayed"
            await metricsLog?.record(.episodeDeleted, detail: reason)
        } catch { loadError = "This episode could not be removed. Its other library entries are safe." }
    }

    func dismissError() { loadError = nil }

    /// The hosts' current identities, for the "Meet the hosts" sheet — the
    /// same profile that shapes the next episode's dialogue and that the
    /// episode just finished evolves in turn.
    func currentHostPersonas() async -> HostPersonaProfile { await HostPersonaStore.shared.current() }

    /// Extracts text locally via PDFKit and drops it straight into the same
    /// source field pasted text or a URL would use — the rest of the studio
    /// flow doesn't need to know where the text came from.
    func importPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isImportingPDF = true
        studioMessage = nil
        Task { [weak self] in
            defer { self?.isImportingPDF = false }
            do {
                // A long PDF takes seconds to extract; on the main actor that
                // is a frozen window with no explanation.
                let text = try await Task.detached(priority: .userInitiated) {
                    try PDFArticleExtractor.extractText(from: url)
                }.value
                guard let self else { return }
                self.sourceText = text
                if self.studioTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.studioTitle = url.deletingPathExtension().lastPathComponent
                }
            } catch {
                self?.studioMessage = "ReaderFlow could not read that PDF: \(error.localizedDescription)"
            }
        }
    }

    func createDraft() async {
        isGenerating = true; studioMessage = nil
        defer { isGenerating = false }
        await metricsLog?.record(.generationStarted)
        do {
            let draft = try await EpisodeGenerationService.makeDraft(source: sourceText, detail: detailLevel, style: contentStyle, localAI: localAI, progress: studioProgress)
            draftScript = draft.script
            // Only overwrite a title the user hasn't already typed in themselves.
            if studioTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { studioTitle = draft.title }
            studioMessage = "Draft ready. Review it, then render it with the two-host Kokoro engine."
        } catch {
            studioMessage = "ReaderFlow could not create the draft: \(error.localizedDescription)"
            await metricsLog?.record(.generationFailed, detail: "draft")
        }
    }

    /// Starts the audio render in the background and returns immediately so the
    /// studio sheet can close without blocking on the slow synthesis step.
    /// Progress and failures surface through `pendingRender` and `loadError`.
    func startRendering() {
        guard let store else { studioMessage = "The local library is still opening. Try again."; return }
        let script = draftScript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { studioMessage = "Create or paste a script before rendering audio."; return }
        guard pendingRender == nil else { return }
        let title = studioTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.untitledPlaceholder : studioTitle
        let style = contentStyle
        pendingRender = PendingRender(title: title, stage: .renderingAudio)
        draftScript = ""; sourceText = ""; studioTitle = ""; detailLevel = .depth; contentStyle = .conversational; studioMessage = nil
        Task { [weak self, localAI] in
            guard let self else { return }
            do {
                _ = try await EpisodeGenerationService.save(script: script, title: title, style: style, localAI: localAI, store: store) { [weak self] stage in
                    Task { @MainActor in self?.pendingRender?.stage = stage }
                }
                self.episodes = await store.allEpisodes()
                self.pendingRender = nil
                await self.metricsLog?.record(.generationSucceeded)
            } catch {
                self.pendingRender = nil
                // Put the script back in the studio rather than discarding
                // work the user may have hand-edited. A failed render is
                // usually retryable, and the draft is the expensive part.
                self.draftScript = script
                self.studioTitle = title == Self.untitledPlaceholder ? "" : title
                self.contentStyle = style
                self.loadError = "\(title) could not be created: \(error.localizedDescription) Your script has been restored so you can try rendering again."
                await self.metricsLog?.record(.generationFailed, detail: "render")
            }
        }
    }

    private var studioProgress: EpisodeGenerationService.ProgressHandler {
        { [weak self] stage in
            Task { @MainActor [weak self] in self?.studioMessage = stage.userMessage }
        }
    }
}

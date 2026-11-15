import AVFoundation
import Combine
import Foundation

@MainActor
final class ReaderFlowAppModel: ObservableObject {
    @Published var episodes: [ListenerEpisode] = []
    @Published var selectedEpisodeID: ListenerEpisode.ID?
    @Published var scriptDraft: ScriptDraft?
    @Published var isGenerating = false
    @Published var isRenderingAudio = false
    @Published var generationMessage: String?
    @Published var playbackRate: Float = 1
    @Published var isPlaying = false
    @Published var selectedTab = 0

    private let generator: any ScriptGenerating = OnDeviceScriptGenerator()
    private let library = EpisodeLibrary()
    private let narration = SystemNarrationRenderer()
    private let player = LocalEpisodePlayer()
    private var sourceArticle = ""

    init() {
        episodes = library.load()
        selectedEpisodeID = episodes.first?.id
        player.onUpdate = { [weak self] elapsed, duration, isPlaying in
            guard let self, let id = self.selectedEpisodeID,
                  let index = self.episodes.firstIndex(where: { $0.id == id }) else { return }
            self.episodes[index].duration = duration
            self.episodes[index].progress = duration > 0 ? elapsed / duration : 0
            self.isPlaying = isPlaying
        }
    }

    var selectedEpisode: ListenerEpisode? {
        episodes.first { $0.id == selectedEpisodeID } ?? episodes.first
    }

    var generationAvailability: GenerationAvailability { generator.availability() }

    func createDraft(from article: String) async {
        isGenerating = true
        generationMessage = nil
        defer { isGenerating = false }
        do {
            let resolvedArticle = try await ArticleInputResolver.resolve(article)
            sourceArticle = resolvedArticle
            scriptDraft = try await generator.generate(article: resolvedArticle)
        } catch {
            generationMessage = error.localizedDescription
        }
    }

    /// Lets a listener render a script they have already prepared when Apple
    /// Intelligence is not available on their phone.
    func usePastedTextAsScript(_ text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        if ArticleInputResolver.webURL(from: body) != nil {
            generationMessage = "A web link needs to be fetched first. Use Create local draft, or paste a script instead."
            return
        }
        sourceArticle = body
        scriptDraft = ScriptDraft(
            title: "My local episode",
            body: body,
            createdAt: .now,
            isRevised: false
        )
        generationMessage = "Using your pasted text as the episode script."
    }

    func reviseCurrentDraft() async {
        guard let scriptDraft else { return }
        isGenerating = true
        generationMessage = nil
        defer { isGenerating = false }
        do {
            self.scriptDraft = try await generator.revise(draft: scriptDraft, article: sourceArticle)
        } catch {
            generationMessage = error.localizedDescription
        }
    }

    func setSelected(_ episode: ListenerEpisode) {
        selectedEpisodeID = episode.id
    }

    func createAudioEpisode() async {
        guard let scriptDraft else { return }
        isRenderingAudio = true
        generationMessage = nil
        defer { isRenderingAudio = false }
        do {
            let outputURL = library.newAudioURL()
            let duration = try await narration.render(script: scriptDraft.body, to: outputURL)
            let episode = ListenerEpisode(
                id: UUID(), title: scriptDraft.title, source: "On-device studio", duration: duration,
                progress: 0, summary: "Created locally on this iPhone.", state: .ready,
                createdAt: .now, audioFilename: outputURL.lastPathComponent
            )
            episodes.insert(episode, at: 0)
            selectedEpisodeID = episode.id
            try library.save(episodes)
            selectedTab = 0
            generationMessage = "Audio is ready in Listen."
        } catch {
            generationMessage = error.localizedDescription
        }
    }

    func togglePlayback() {
        guard let episode = selectedEpisode, let filename = episode.audioFilename else { return }
        do {
            try player.toggle(url: library.audioURL(for: filename), rate: playbackRate)
        } catch {
            generationMessage = "Audio could not be played. Generate the episode again."
        }
    }

    func seek(to progress: Double) { player.seek(to: progress) }

    func setPlaybackRate(_ rate: Float) { playbackRate = rate; player.setRate(rate) }

    func delete(_ episode: ListenerEpisode) {
        if let filename = episode.audioFilename { try? FileManager.default.removeItem(at: library.audioURL(for: filename)) }
        episodes.removeAll { $0.id == episode.id }
        selectedEpisodeID = episodes.first?.id
        try? library.save(episodes)
    }
}

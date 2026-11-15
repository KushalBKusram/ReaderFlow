import Foundation
#if !READERFLOW_APP
import ReaderFlowEpisodeLibrary
#endif

struct GeneratedEpisode {
    let episode: Episode
    let article: String
    let script: String
    let audioURL: URL
}

struct GeneratedDraft {
    let article: String
    let script: String
    let title: String
}

enum EpisodeGenerationStage: String, Sendable {
    case extractingArticle = "extracting_article"
    case generatingScript = "generating_script"
    case renderingAudio = "rendering_audio"
    case savingEpisode = "saving_episode"

    var userMessage: String {
        switch self {
        case .extractingArticle: "Reading the public article locally…"
        case .generatingScript: "Writing your local conversation…"
        case .renderingAudio: "Rendering expressive audio privately on this Mac…"
        case .savingEpisode: "Saving the episode to your local library…"
        }
    }
}

/// The complete local episode path, shared by the UI and the app's internal
/// end-to-end runner. Nothing in this service uses a network model API.
enum EpisodeGenerationService {
    typealias ProgressHandler = @Sendable (EpisodeGenerationStage) -> Void

    static func makeDraft(source: String, detail: EpisodeDetailLevel = .depth, style: EpisodeContentStyle = .conversational, localAI: LocalAISetup, progress: ProgressHandler? = nil) async throws -> GeneratedDraft {
        progress?(.extractingArticle)
        let article = try await ArticleInputResolver.resolve(source)
        progress?(.generatingScript)
        let modelDirectory = try localAI.qwenModelDirectory()
        let script = try await QwenStudio.makeConversation(from: article, detail: detail, style: style, modelDirectory: modelDirectory)
        // A generated title is a convenience default; a title-less draft is
        // still fully usable, so a failure here should not fail the draft.
        let title = (try? await QwenStudio.makeTitle(from: article, modelDirectory: modelDirectory)) ?? "ReaderFlow conversation"
        return GeneratedDraft(article: article, script: script, title: title)
    }

    static func create(source: String, title: String, detail: EpisodeDetailLevel = .depth, style: EpisodeContentStyle = .conversational, localAI: LocalAISetup, progress: ProgressHandler? = nil) async throws -> GeneratedEpisode {
        let draft = try await makeDraft(source: source, detail: detail, style: style, localAI: localAI, progress: progress)
        return try await save(script: draft.script, title: title, style: style, article: draft.article, localAI: localAI, progress: progress)
    }

    /// Reuses `store` when the caller already owns a live instance (the app's
    /// in-memory library) instead of opening a second `EpisodeLibraryStore` on
    /// the same files — that would re-decode the whole index from disk and
    /// leave the caller's own in-memory copy unaware of the new episode.
    static func save(script: String, title: String, style: EpisodeContentStyle = .conversational, article: String = "", localAI: LocalAISetup, store: EpisodeLibraryStore? = nil, progress: ProgressHandler? = nil) async throws -> GeneratedEpisode {
        let root = try EpisodeLibraryStore.defaultRootURL()
        let id = UUID()
        let relative = "episodes/\(id.uuidString)"
        let directory = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let scriptURL = directory.appendingPathComponent("script.txt")
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            let renderedURL = directory.appendingPathComponent("audio.wav")
            let duration = try await KokoroEpisodeRenderer.render(
                script: script,
                to: renderedURL,
                pythonURL: try localAI.kokoroPythonURL(),
                modelDirectory: try localAI.kokoroModelDirectory(),
                voices: style.voices,
                progress: { _ in progress?(.renderingAudio) }
            )
            progress?(.savingEpisode)
            // Duration is measured from the WAV above, so compression can't
            // shift it. Older episodes keep their recorded .wav path and
            // keep playing untouched; only new ones are stored compressed.
            let audioURL = await EpisodeAudioCompressor.compress(renderedURL)
            let manifest = try EpisodeManifest(voices: style.voices).encoded()
            try manifest.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
            let episode = Episode(
                id: id,
                title: title,
                displayMetadata: .init(sourceLabel: "Created locally on this Mac"),
                scriptPath: "\(relative)/script.txt",
                audioPath: "\(relative)/\(audioURL.lastPathComponent)",
                artifactManifestPath: "\(relative)/manifest.json",
                audioDuration: duration
            )
            let library = try store ?? EpisodeLibraryStore(rootURL: root)
            try await library.upsert(episode)
            _ = try await library.refreshRecoveryState(for: id)
            // Only now, with the episode actually in the library, do the hosts
            // carry anything forward from it.
            if let modelDirectory = try? localAI.qwenModelDirectory() {
                await QwenStudio.evolveHostPersonas(after: script, modelDirectory: modelDirectory)
            }
            return GeneratedEpisode(episode: episode, article: article, script: script, audioURL: audioURL)
        } catch {
            // This directory never made it into the library index, so nothing
            // will ever surface or clean it up later. Left behind, failed
            // renders silently accumulate invisible script text and partial
            // audio in Application Support.
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

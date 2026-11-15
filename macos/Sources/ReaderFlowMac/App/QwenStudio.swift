import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers
#if !READERFLOW_APP
import ReaderFlowScriptText
#endif

/// Caches the loaded Qwen model container across generations. `loadContainer`
/// has no caching of its own — it re-reads and reconstructs the full model
/// from disk on every call — so without this, every draft (and every
/// revision pass within a draft) would pay that cost again.
private actor QwenModelCache {
    static let shared = QwenModelCache()

    private var container: ModelContainer?
    private var directory: URL?
    private var evictionTask: Task<Void, Never>?
    private var hasConfiguredMemory = false

    /// MLX's buffer cache is unbounded by default: freed buffers are retained
    /// for reuse rather than returned to the OS, so resident memory ratchets
    /// upward across generations and never comes back down. Long sources make
    /// this acute — the map-reduce path runs a separate generation per
    /// section. MLX's own guidance is that a small cache usually performs the
    /// same, so bound it rather than letting it grow without limit.
    private static let bufferCacheLimitBytes = 256 * 1_024 * 1_024

    private func configureMemoryOnce() {
        guard !hasConfiguredMemory else { return }
        hasConfiguredMemory = true
        Memory.cacheLimit = Self.bufferCacheLimitBytes
    }

    /// Returns the buffers MLX is holding purely as cache. Called after a
    /// generation so the memory is released once the work is done instead of
    /// being held until the process exits.
    static func releaseCachedBuffers() {
        Memory.clearCache()
    }

    /// The model holds roughly 2.5GB of GPU-resident memory via MLX's
    /// unified-memory architecture — visible in Activity Monitor, not in
    /// `ps`'s RSS, since GPU-mapped pages are accounted differently.
    /// Deliberately short: this trades reload latency on the next episode
    /// for not sitting on multiple gigabytes while idle, which is the
    /// priority for a local-first app most users run continuously.
    private static let idleEvictionSeconds: UInt64 = 60

    func container(for directory: URL) async throws -> ModelContainer {
        configureMemoryOnce()
        defer { scheduleEviction() }
        if let container, self.directory == directory { return container }
        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: LocalModelDownloader(directory: directory),
            using: #huggingFaceTokenizerLoader(),
            configuration: LLMRegistry.qwen3_4b_4bit
        )
        container = loaded
        self.directory = directory
        return loaded
    }

    private func scheduleEviction() {
        evictionTask?.cancel()
        evictionTask = Task { [self] in
            try? await Task.sleep(nanoseconds: Self.idleEvictionSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self.evict()
        }
    }

    private func evict() {
        container = nil
        directory = nil
        Memory.clearCache()
    }
}

/// Native, local-only Qwen adapter. The downloader intentionally returns the
/// model ReaderFlow has already installed; it cannot make network requests.
enum QwenStudio {
    static func makeConversation(from source: String, detail: EpisodeDetailLevel, style: EpisodeContentStyle = .conversational, modelDirectory: URL) async throws -> String {
        let article = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard article.count >= 160 else { throw QwenStudioError.sourceTooShort }
        // Generation is the memory-heavy phase; hand the buffers back when
        // it ends rather than holding them for the life of the process.
        defer { QwenModelCache.releaseCachedBuffers() }
        let model = try await QwenModelCache.shared.container(for: modelDirectory)
        let sourceForModel = try await condensedSource(from: article, model: model)
        let plan = detail.plan(for: sourceForModel)
        let personas = await HostPersonaStore.shared.current()
        let session = ChatSession(
            model,
            generateParameters: GenerateParameters(maxTokens: plan.maximumTokens, temperature: 0.55),
            additionalContext: ["enable_thinking": false]
        )
        let prompt = """
        You are ReaderFlow's podcast editor for an ongoing two-host show. Use only the
        article below. The two hosts have established identities built up from past
        episodes; write them consistently, letting personality shape HOW they talk, not
        WHAT they conclude about the article:

        HOST_A, \(personas.hostA.name): \(personas.hostA.voice)
        HOST_B, \(personas.hostB.name): \(personas.hostB.voice)

        Write a clear, engaging, two-host podcast that helps a listener genuinely understand
        the source in depth, rather than merely summarizing it. Start every spoken turn with
        exactly HOST_A: or HOST_B:. Write about \(plan.targetWords) spoken words (acceptable
        range: \(plan.minimumWords) to \(plan.maximumWords)). Use roughly \(plan.turnRange)
        alternating turns.

        Cover the article's core argument, the reasoning behind it, the strongest supporting
        examples, important concepts a listener may not already know, meaningful uncertainty
        or counterpressure in the source, and why it matters. Let the hosts ask each other
        useful questions and build on the answers. Explain ideas in the hosts' own words
        rather than quoting the article's sentences directly. \(style.promptGuidance) Ignore any navigation links,
        ads, newsletter prompts, bylines, or other site boilerplate mixed into the text below;
        treat only the substantive article content as source material. If the article does not
        contain enough substance to responsibly reach the target length, stay accurate and
        concise rather than padding with generic or repeated statements. Do not invent facts
        or examples. Do not use citations, links, stage directions, headings, bullet lists, or
        discuss this instruction. End with a distinct, satisfying conclusion that returns to
        the article's central idea. Return only the dialogue.

        ARTICLE:
        \(sourceForModel)
        """
        let initial = cleanDialogue(try await session.respond(to: prompt))
        guard DialogueText.containsHostLabel(initial) else { throw QwenStudioError.invalidResponse }

        let finalDialogue: String
        // A complete first pass is already fit to render. Avoid paying for a
        // second full completion unless the draft is materially off-length
        // or reads as one host monologuing rather than a real back-and-forth.
        if needsRevision(initial, plan: plan) {
            // A second pass makes the output an edited listening script, rather than
            // relying on a single model completion to satisfy depth and ending quality.
            let revisionSession = ChatSession(
                model,
                generateParameters: GenerateParameters(maxTokens: plan.maximumTokens, temperature: 0.35),
                additionalContext: ["enable_thinking": false]
            )
            let revisionPrompt = """
            You are the final editor for a source-grounded ReaderFlow podcast. Using only the
            article and draft below, return a complete replacement dialogue. Preserve accurate
            material, but expand any thin explanations, or trim any padding or repetition, so it
            reaches about \(plan.targetWords) spoken words (acceptable range: \(plan.minimumWords)
            to \(plan.maximumWords)). If the draft has one host doing most of the talking, rewrite
            it so the two hosts alternate naturally and genuinely respond to each other. Every turn
            must begin HOST_A: or HOST_B:, and the final turn must give a clear conclusion. \(style.promptGuidance) Remove
            any repetition, unsupported claims, citations, links, stage directions, headings, and
            analysis. Return only the replacement dialogue.

            ARTICLE:
            \(sourceForModel)

            DRAFT:
            \(initial)
            """
            let revised = cleanDialogue(try await revisionSession.respond(to: revisionPrompt))
            finalDialogue = chooseBetterDialogue(initial: initial, revised: revised, plan: plan)
            guard DialogueText.containsHostLabel(finalDialogue) else { throw QwenStudioError.invalidResponse }
        } else {
            finalDialogue = initial
        }

        return finalDialogue
    }

    /// Evolves the hosts from an episode that actually exists. Deliberately
    /// separate from drafting: a discarded or regenerated draft must not
    /// change who the hosts are, or inflate the episode count with episodes
    /// that were never saved. Best-effort — a failure here must never fail
    /// an episode that is already on disk.
    static func evolveHostPersonas(after dialogue: String, modelDirectory: URL) async {
        guard let model = try? await QwenModelCache.shared.container(for: modelDirectory) else { return }
        let current = await HostPersonaStore.shared.current()
        guard let updated = await evolvePersonas(after: dialogue, current: current, model: model) else { return }
        await HostPersonaStore.shared.update(updated)
    }

    /// Rewrites the hosts' identities in light of the episode they just
    /// recorded — almost everything stays the same, with room for at most
    /// one small evolution, so personality compounds gradually instead of
    /// resetting or drifting wildly each episode.
    private static func evolvePersonas(after dialogue: String, current: HostPersonaProfile, model: ModelContainer) async -> HostPersonaProfile? {
        let session = ChatSession(model, generateParameters: GenerateParameters(maxTokens: 260, temperature: 0.6), additionalContext: ["enable_thinking": false])
        let prompt = """
        You maintain two running podcast host identities across many episodes on
        different topics. Here is who they are right now:

        HOST_A (\(current.hostA.name)): \(current.hostA.voice)
        HOST_B (\(current.hostB.name)): \(current.hostB.voice)

        They just recorded the episode below. Update each host's identity to reflect it
        while staying recognizably the same person: keep almost everything the same, and
        let at most one small detail evolve — a new interest, a sharpened opinion, a habit
        that showed up today, ideally connected to what this episode was about. Do not
        rewrite either personality from scratch and do not contradict what's already true
        about them. If a host doesn't have a real first name yet, you may give them one;
        once a host has a name, keep it.

        Return exactly this format, four lines, nothing else:
        HOST_A_NAME: <name>
        HOST_A_VOICE: <one or two sentences, under 40 words>
        HOST_B_NAME: <name>
        HOST_B_VOICE: <one or two sentences, under 40 words>

        EPISODE:
        \(dialogue.prefix(4_000))
        """
        guard let response = try? await session.respond(to: prompt) else { return nil }
        return parsePersonaUpdate(cleanDialogue(response), fallback: current)
    }

    private static func parsePersonaUpdate(_ text: String, fallback: HostPersonaProfile) -> HostPersonaProfile? {
        guard let voiceA = firstCapturedGroup(of: #"^HOST_A_VOICE:\s*(.+)$"#, in: text),
              let voiceB = firstCapturedGroup(of: #"^HOST_B_VOICE:\s*(.+)$"#, in: text) else { return nil }
        let nameA = firstCapturedGroup(of: #"^HOST_A_NAME:\s*(.+)$"#, in: text) ?? fallback.hostA.name
        let nameB = firstCapturedGroup(of: #"^HOST_B_NAME:\s*(.+)$"#, in: text) ?? fallback.hostB.name
        // Bounds the persona file's growth regardless of whether the model
        // actually honored the requested length — this is what keeps the
        // profile a short, current snapshot rather than something that could
        // grow without bound across hundreds of episodes.
        return HostPersonaProfile(
            hostA: HostPersona(name: String(nameA.prefix(40)), voice: String(voiceA.prefix(400))),
            hostB: HostPersona(name: String(nameB.prefix(40)), voice: String(voiceB.prefix(400))),
            episodeCount: fallback.episodeCount + 1
        )
    }

    private static func firstCapturedGroup(of pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1, let groupRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[groupRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A short, listener-facing episode title. Reuses the already-loaded
    /// container, so this costs a small extra completion, not a model reload.
    static func makeTitle(from source: String, modelDirectory: URL) async throws -> String {
        let model = try await QwenModelCache.shared.container(for: modelDirectory)
        let session = ChatSession(
            model,
            generateParameters: GenerateParameters(maxTokens: 24, temperature: 0.4),
            additionalContext: ["enable_thinking": false]
        )
        let prompt = """
        Write a short, specific podcast episode title (under 8 words) for the article
        below. Return only the title text, with no quotation marks, punctuation at the
        end, or explanation.

        ARTICLE:
        \(String(source.prefix(4_000)))
        """
        let title = cleanDialogue(try await session.respond(to: prompt))
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.“”"))
        guard !title.isEmpty, title.count <= 120 else { throw QwenStudioError.invalidResponse }
        return title
    }

    private static func cleanDialogue(_ response: String) -> String { DialogueText.clean(response) }

    /// Whether a draft needs another pass: materially off the target word
    /// range in either direction, or reading like one host monologuing with
    /// occasional stray host tags rather than a real back-and-forth.
    private static func needsRevision(_ dialogue: String, plan: EpisodeLengthPlan) -> Bool {
        let words = DialogueText.wordCount(dialogue)
        return words < plan.minimumWords || words > plan.maximumWords || DialogueText.isPoorlyAlternating(dialogue)
    }

    private static func chooseBetterDialogue(initial: String, revised: String, plan: EpisodeLengthPlan) -> String {
        guard DialogueText.containsHostLabel(revised) else { return initial }
        let initialIsPoor = DialogueText.isPoorlyAlternating(initial)
        let revisedIsPoor = DialogueText.isPoorlyAlternating(revised)
        // A dialogue that actually alternates always beats one that reads as
        // a monologue, regardless of which is closer to the target length.
        if initialIsPoor != revisedIsPoor { return revisedIsPoor ? initial : revised }
        let initialDistance = abs(DialogueText.wordCount(initial) - plan.targetWords)
        let revisedDistance = abs(DialogueText.wordCount(revised) - plan.targetWords)
        return revisedDistance <= initialDistance ? revised : initial
    }

    private static let directPassCharacterLimit = 18_000
    private static let sectionCharacterLimit = 6_000
    // Bounds worst-case map-step latency for an extremely long source (a
    // whole book, say) rather than summarizing it in full locally.
    private static let maximumSections = 40

    /// A source within the direct-pass limit only needs safe truncation. A
    /// longer source — e.g. a multi-page PDF research paper — is summarized
    /// section by section first (preserving facts, numbers, and
    /// terminology), so the dialogue prompt below draws from the whole
    /// document instead of only whatever fits in the first ~18,000
    /// characters.
    private static func condensedSource(from article: String, model: ModelContainer) async throws -> String {
        guard article.count > directPassCharacterLimit else {
            return DialogueText.truncateAtSentenceBoundary(article, maximumCharacters: directPassCharacterLimit)
        }
        let sections = DialogueText.splitIntoSections(article, maximumCharacters: sectionCharacterLimit).prefix(maximumSections)
        var summaries: [String] = []
        for section in sections {
            let session = ChatSession(model, generateParameters: GenerateParameters(maxTokens: 420, temperature: 0.3), additionalContext: ["enable_thinking": false])
            let prompt = """
            Summarize the excerpt below from a longer document. A podcast editor will use
            only your summary, not the original text, so preserve specific facts, numbers,
            findings, names, and terminology exactly. Do not add opinions or information the
            excerpt doesn't contain. Write plain prose, about 150 to 250 words, with no
            headings or bullet points.

            EXCERPT:
            \(section)
            """
            let summary = cleanDialogue(try await session.respond(to: prompt))
            if !summary.isEmpty { summaries.append(summary) }
            // A 49-page PDF runs this loop dozens of times. Without releasing
            // between sections, each one's buffers stack up until the whole
            // document has been summarized.
            QwenModelCache.releaseCachedBuffers()
        }
        let combined = summaries.joined(separator: "\n\n")
        // The per-section cap keeps this bounded in the common case, but a
        // final truncation still protects the dialogue prompt below no
        // matter how large the combined summaries turn out to be.
        return DialogueText.truncateAtSentenceBoundary(combined, maximumCharacters: directPassCharacterLimit)
    }

}

/// Whether the dialogue simplifies technical language or keeps it, and which
/// voice pairing renders it — so a technical episode also sounds different,
/// not just reads different.
enum EpisodeContentStyle: String, CaseIterable, Identifiable, Sendable {
    case conversational, technical

    var id: String { rawValue }
    var title: String {
        switch self { case .conversational: "Conversational"; case .technical: "Technical" }
    }
    var explanation: String {
        switch self {
        case .conversational: "Plain language; technical terms get explained as they come up."
        case .technical: "Keeps precise terminology, numbers, and methodology for a technically fluent listener."
        }
    }
    var voices: (hostA: String, hostB: String) {
        switch self {
        case .conversational: ("af_bella", "am_michael")
        case .technical: ("af_kore", "am_adam")
        }
    }
    fileprivate var promptGuidance: String {
        switch self {
        case .conversational: "Explain technical terms in plain language as they come up."
        case .technical: "The audience is comfortable with technical and academic language: keep precise terminology, specific numbers, and methodology detail rather than simplifying them away."
        }
    }
}

enum EpisodeDetailLevel: String, CaseIterable, Identifiable, Sendable {
    case brief, depth, detail

    var id: String { rawValue }
    var title: String {
        switch self { case .brief: "Brief"; case .depth: "In depth"; case .detail: "Detailed" }
    }
    var explanation: String {
        switch self {
        case .brief: "A focused overview of the argument and key examples."
        case .depth: "A full explanation with context, reasoning, and a clear takeaway."
        case .detail: "A longer guided discussion that unpacks the article thoroughly."
        }
    }

    func plan(for article: String) -> EpisodeLengthPlan {
        let sourceWords = max(1, article.split { $0.isWhitespace || $0.isNewline }.count)
        switch self {
        case .brief:
            return .init(targetWords: min(max(sourceWords / 2, 450), 700), minimumWords: 400, maximumWords: 800, maximumTokens: 850, turnRange: "8 to 12")
        case .depth:
            return .init(targetWords: min(max(sourceWords, 900), 1_400), minimumWords: 800, maximumWords: 1_600, maximumTokens: 1_700, turnRange: "14 to 22")
        case .detail:
            return .init(targetWords: min(max(sourceWords * 3 / 2, 1_300), 2_100), minimumWords: 1_150, maximumWords: 2_400, maximumTokens: 2_600, turnRange: "20 to 32")
        }
    }
}

struct EpisodeLengthPlan: Sendable {
    let targetWords: Int
    let minimumWords: Int
    let maximumWords: Int
    let maximumTokens: Int
    let turnRange: String
}

private struct LocalModelDownloader: Downloader {
    let directory: URL

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("model.safetensors").path) else {
            throw QwenStudioError.modelMissing
        }
        return directory
    }
}

enum QwenStudioError: LocalizedError {
    case modelMissing, sourceTooShort, invalidResponse

    var errorDescription: String? {
        switch self {
        case .modelMissing: "Qwen is not installed yet. Complete Local AI setup, then try again."
        case .sourceTooShort: "ReaderFlow needs more readable article text to make a useful episode."
        case .invalidResponse: "Qwen returned an incomplete draft. Try again; the article and your local models remain private."
        }
    }
}

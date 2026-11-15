import Foundation
import AVFoundation
#if canImport(FoundationModels)
import FoundationModels
#endif

protocol ScriptGenerating {
    func availability() -> GenerationAvailability
    func generate(article: String) async throws -> ScriptDraft
    func revise(draft: ScriptDraft, article: String) async throws -> ScriptDraft
}

enum ScriptGenerationError: LocalizedError {
    case unavailable(String)
    case emptyArticle

    var errorDescription: String? {
        switch self {
        case let .unavailable(message): return message
        case .emptyArticle: return "Paste an article before creating a draft."
        }
    }
}

struct OnDeviceScriptGenerator: ScriptGenerating {
    func availability() -> GenerationAvailability {
        if #available(iOS 26.0, *) {
            return .ready
        }
        return .unavailable("On-device script generation requires a compatible iPhone with iOS 26 or later. You can still receive and listen to paired episodes here.")
    }

    func generate(article: String) async throws -> ScriptDraft {
        let trimmedArticle = article.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArticle.isEmpty else {
            throw ScriptGenerationError.emptyArticle
        }
        guard #available(iOS 26.0, *) else {
            throw ScriptGenerationError.unavailable("On-device script generation is unavailable on this device.")
        }
        return try await generateWithFoundationModels(article: article)
    }

    @available(iOS 26.0, *)
    private func generateWithFoundationModels(article: String) async throws -> ScriptDraft {
        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw ScriptGenerationError.unavailable("Apple Intelligence is not currently available. Finish device setup or use the desktop studio.")
        }
        let sourceNotes = try await SourceGroundingReducer.makeNotes(for: article)
        let session = LanguageModelSession(instructions: "You are ReaderFlow's careful podcast editor. Use only the supplied article. Write a concise conversational two-host draft with complete sentences, a clear conclusion, and no citations, brackets, or meta commentary.")
        let response = try await session.respond(to: "Create a polished podcast script from these source-grounded notes:\n\n\(sourceNotes)", options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 900))
        return ScriptDraft(title: "New local draft", body: response.content, createdAt: .now, isRevised: false)
        #else
        throw ScriptGenerationError.unavailable("This app build does not include the Apple Foundation Models framework.")
        #endif
    }

    func revise(draft: ScriptDraft, article: String) async throws -> ScriptDraft {
        guard #available(iOS 26.0, *) else {
            throw ScriptGenerationError.unavailable("On-device revision is unavailable on this device.")
        }
        return try await reviseWithFoundationModels(draft: draft, article: article)
    }

    @available(iOS 26.0, *)
    private func reviseWithFoundationModels(draft: ScriptDraft, article: String) async throws -> ScriptDraft {
        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw ScriptGenerationError.unavailable("Apple Intelligence is not currently available. Finish device setup or use the desktop studio.")
        }
        let sourceExcerpt = SourceGroundingReducer.boundedExcerpt(from: article)
        let session = LanguageModelSession(instructions: "You are ReaderFlow's final podcast editor. Use only the supplied article to revise the draft. Remove repetition, fragments, citations, brackets, placeholders, and meta commentary. Keep the dialogue conversational and source-grounded. End with a brief, complete conclusion. Return only HOST_A: or HOST_B: lines.")
        let response = try await session.respond(to: "SOURCE EXCERPT:\n\(sourceExcerpt)\n\nDRAFT TO REVISE:\n\(draft.body)", options: GenerationOptions(temperature: 0.1, maximumResponseTokens: 900))
        return ScriptDraft(title: "Revised local draft", body: response.content, createdAt: .now, isRevised: true)
        #else
        throw ScriptGenerationError.unavailable("This app build does not include the Apple Foundation Models framework.")
        #endif
    }
}

@available(iOS 26.0, *)
enum SourceGroundingReducer {
    /// Keep every Foundation Models request comfortably below the small local
    /// model's context window. A fresh session per excerpt prevents a long
    /// article's transcript from accumulating across requests.
    static func makeNotes(for article: String) async throws -> String {
        let excerpts = chunks(from: article, maximumCharacters: 4_500)
        if excerpts.count == 1 { return excerpts[0] }

        var notes: [String] = []
        for (index, excerpt) in excerpts.prefix(8).enumerated() {
            let session = LanguageModelSession(instructions: "You are a careful source reader. Extract only the concrete claims, evidence, names, numbers, and conclusion from the provided article excerpt. Do not add knowledge, commentary, or citations. Return compact factual notes.")
            let response = try await session.respond(
                to: "Excerpt \(index + 1) of \(min(excerpts.count, 8)):\n\n\(excerpt)",
                options: GenerationOptions(temperature: 0, maximumResponseTokens: 240)
            )
            notes.append(response.content)
        }
        return boundedExcerpt(from: notes.joined(separator: "\n\n"))
    }

    static func boundedExcerpt(from text: String) -> String {
        String(text.prefix(7_000))
    }

    private static func chunks(from text: String, maximumCharacters: Int) -> [String] {
        let paragraphs = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var chunks: [String] = []
        var current = ""
        for paragraph in paragraphs {
            if paragraph.count > maximumCharacters {
                if !current.isEmpty { chunks.append(current); current = "" }
                var remainder = paragraph[...]
                while !remainder.isEmpty {
                    let end = remainder.index(remainder.startIndex, offsetBy: min(maximumCharacters, remainder.count))
                    chunks.append(String(remainder[..<end]))
                    remainder = remainder[end...]
                }
            } else if current.count + paragraph.count + 2 > maximumCharacters, !current.isEmpty {
                chunks.append(current)
                current = paragraph
            } else {
                current += current.isEmpty ? paragraph : "\n\n\(paragraph)"
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.isEmpty ? [String(text.prefix(maximumCharacters))] : chunks
    }
}

enum ArticleExtractionError: LocalizedError {
    case invalidURL
    case unsupportedResponse
    case pageTooLarge
    case noReadableText

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter a public http or https web link, or paste article text."
        case .unsupportedResponse: return "ReaderFlow could not retrieve a readable public article from that link. It may require a sign-in, be paywalled, or not be an HTML page."
        case .pageTooLarge: return "That page is too large to process on this iPhone. Paste the article text instead."
        case .noReadableText: return "ReaderFlow could not find readable article text on that page. Paste the article text instead."
        }
    }
}

/// Fetches only public HTML requested by the listener. It uses an ephemeral
/// session without cookies or credentials and never attempts to bypass a
/// sign-in wall or access restriction.
enum ArticleInputResolver {
    private static let maximumBytes = 3_000_000

    static func resolve(_ input: String) async throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ScriptGenerationError.emptyArticle }
        guard let url = webURL(from: trimmed) else { return trimmed }
        return try await fetchReadableText(from: url)
    }

    static func webURL(from input: String) -> URL? {
        guard !input.contains(where: \.isWhitespace),
              let url = URL(string: input),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }

    private static func fetchReadableText(from url: URL) async throws -> String {
        var configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: url)
        request.setValue("ReaderFlow/0.1 (local article reader)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200 ... 299).contains(http.statusCode) else { throw ArticleExtractionError.unsupportedResponse }
        guard data.count <= maximumBytes else { throw ArticleExtractionError.pageTooLarge }
        if let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           !type.contains("text/html") && !type.contains("application/xhtml") {
            throw ArticleExtractionError.unsupportedResponse
        }
        guard let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw ArticleExtractionError.unsupportedResponse
        }
        let text = HTMLReadableTextExtractor.extract(from: html)
        guard text.count >= 160 else { throw ArticleExtractionError.noReadableText }
        return text
    }
}

enum HTMLReadableTextExtractor {
    static func extract(from html: String) -> String {
        let withoutNonContent = replacing("(?is)<(script|style|noscript|svg|nav|footer|aside|form|header)[^>]*>.*?</\\1>", in: html, with: " ")
        let container = firstCapture("(?is)<article[^>]*>(.*?)</article>", in: withoutNonContent)
            ?? firstCapture("(?is)<main[^>]*>(.*?)</main>", in: withoutNonContent)
            ?? firstCapture("(?is)<body[^>]*>(.*?)</body>", in: withoutNonContent)
            ?? withoutNonContent
        let blocks = captures("(?is)<(?:p|h1|h2|h3|li|blockquote)[^>]*>(.*?)</(?:p|h1|h2|h3|li|blockquote)>", in: container)
            .map(text(fromHTML:))
            .filter { $0.count > 24 }
        let result = blocks.isEmpty ? text(fromHTML: container) : blocks.joined(separator: "\n\n")
        return result.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func text(fromHTML html: String) -> String {
        let withBreaks = replacing("(?is)</?(p|div|section|article|main|h[1-6]|li|br|blockquote)[^>]*>", in: html, with: "\n")
        let noTags = replacing("(?is)<[^>]+>", in: withBreaks, with: " ")
        return decodeEntities(noTags)
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ value: String) -> String {
        let named = value
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        return replacing("&#(x[0-9A-Fa-f]+|[0-9]+);", in: named) { match in
            let raw = match.dropFirst(2).dropLast()
            let scalar: UInt32? = raw.first == "x" || raw.first == "X"
                ? UInt32(raw.dropFirst(), radix: 16)
                : UInt32(raw)
            return scalar.flatMap(UnicodeScalar.init).map(String.init) ?? " "
        }
    }

    private static func firstCapture(_ pattern: String, in value: String) -> String? {
        captures(pattern, in: value).first
    }

    private static func captures(_ pattern: String, in value: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: value) else { return nil }
            return String(value[range])
        }
    }

    private static func replacing(_ pattern: String, in value: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        return expression.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: replacement)
    }

    private static func replacing(_ pattern: String, in value: String, transform: (Substring) -> String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let matches = expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed()
        var result = value
        for match in matches {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(result[range]))
        }
        return result
    }
}

enum NarrationError: LocalizedError {
    case unsupported
    case noAudioFrames

    var errorDescription: String? {
        switch self {
        case .unsupported: return "This device does not support local speech rendering."
        case .noAudioFrames: return "The selected system voice did not return audio frames. Try another voice or retry the episode."
        }
    }
}

enum PlaybackError: LocalizedError {
    case couldNotStart

    var errorDescription: String? { "The episode audio could not start." }
}

@MainActor
final class SystemNarrationRenderer: NSObject {
    private var synthesizer: AVSpeechSynthesizer?
    private var outputFile: AVAudioFile?
    private var continuation: CheckedContinuation<TimeInterval, Error>?
    private var framesWritten: AVAudioFramePosition = 0

    func render(script: String, to outputURL: URL) async throws -> TimeInterval {
        let narration = script
            .replacingOccurrences(of: #"(?m)^HOST_[AB]:\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !narration.isEmpty else { throw NarrationError.noAudioFrames }

        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: outputURL)
        framesWritten = 0
        outputFile = nil

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let utterance = AVSpeechUtterance(string: narration)
            utterance.voice = preferredVoice()
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            let synthesizer = AVSpeechSynthesizer()
            self.synthesizer = synthesizer
            synthesizer.write(utterance) { [weak self] buffer in
                Task { @MainActor in self?.consume(buffer: buffer, outputURL: outputURL) }
            }
        }
    }

    private func consume(buffer: AVAudioBuffer, outputURL: URL) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        do {
            if pcm.frameLength == 0 {
                let duration = outputFile.map { Double(framesWritten) / $0.processingFormat.sampleRate } ?? 0
                cleanup()
                guard duration > 0 else { throw NarrationError.noAudioFrames }
                continuation?.resume(returning: duration)
                continuation = nil
                return
            }
            if outputFile == nil {
                outputFile = try AVAudioFile(forWriting: outputURL, settings: pcm.format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            }
            try outputFile?.write(from: pcm)
            framesWritten += AVAudioFramePosition(pcm.frameLength)
        } catch {
            cleanup()
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    private func cleanup() {
        outputFile = nil
        synthesizer = nil
    }

    private func preferredVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        return voices.first(where: { $0.quality == .premium })
            ?? voices.first(where: { $0.quality == .enhanced })
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}

struct EpisodeLibrary {
    private let baseURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        baseURL = support.appendingPathComponent("ReaderFlow", isDirectory: true)
    }

    func load() -> [ListenerEpisode] {
        guard let data = try? Data(contentsOf: manifestURL),
              let episodes = try? JSONDecoder().decode([ListenerEpisode].self, from: data) else { return [] }
        return episodes.sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ episodes: [ListenerEpisode]) throws {
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(episodes)
        try data.write(to: manifestURL, options: .atomic)
    }

    func audioURL(for filename: String) -> URL { baseURL.appendingPathComponent(filename) }
    func newAudioURL() -> URL { baseURL.appendingPathComponent("episode-\(UUID().uuidString).caf") }

    private var manifestURL: URL { baseURL.appendingPathComponent("episodes.json") }
}

@MainActor
final class LocalEpisodePlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var timer: Timer?
    var onUpdate: ((TimeInterval, TimeInterval, Bool) -> Void)?

    func toggle(url: URL, rate: Float) throws {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        if let player, player.url == url {
            if player.isPlaying {
                pause()
            } else {
                player.rate = rate
                guard player.play() else { throw PlaybackError.couldNotStart }
                beginUpdates()
            }
            publish()
            return
        }
        timer?.invalidate()
        let next = try AVAudioPlayer(contentsOf: url)
        next.enableRate = true
        next.rate = rate
        next.delegate = self
        next.prepareToPlay()
        player = next
        guard next.play() else { throw PlaybackError.couldNotStart }
        beginUpdates()
        publish()
    }

    func seek(to progress: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(player.duration, player.duration * progress))
        publish()
    }

    func setRate(_ rate: Float) { player?.rate = rate }
    func pause() { player?.pause(); timer?.invalidate(); publish() }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finishPlayback() }
    }

    private func finishPlayback() {
        timer?.invalidate()
        publish()
    }

    private func beginUpdates() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }
    }

    private func publish() {
        guard let player else { return }
        onUpdate?(player.currentTime, player.duration, player.isPlaying)
    }
}

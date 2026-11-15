import AVFoundation
import Foundation

enum KokoroRenderBackend: Sendable {
    case cpu
}

/// Kokoro emits uncompressed 24kHz mono WAV — about 2.9MB per minute, so a
/// ten-minute episode costs ~30MB. Re-encoding to AAC measures ~11x smaller
/// with no audible difference at this bitrate, which matters both for local
/// library size and for eventually transferring episodes to a phone.
enum EpisodeAudioCompressor {
    /// Returns the compressed file's URL, or the original WAV if compression
    /// fails — a larger episode is a much better outcome than a lost one.
    static func compress(_ wavURL: URL) async -> URL {
        let m4aURL = wavURL.deletingPathExtension().appendingPathExtension("m4a")
        try? FileManager.default.removeItem(at: m4aURL)
        let asset = AVURLAsset(url: wavURL)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return wavURL }
        do {
            if #available(macOS 15.0, *) {
                try await export.export(to: m4aURL, as: .m4a)
            } else {
                export.outputURL = m4aURL
                export.outputFileType = .m4a
                await export.export()
                guard export.status == .completed else { return wavURL }
            }
        } catch {
            return wavURL
        }
        // Only drop the source once the replacement is known-readable by the
        // same API the library uses to decide an episode is playable.
        guard (try? AVAudioFile(forReading: m4aURL)) != nil else {
            try? FileManager.default.removeItem(at: m4aURL)
            return wavURL
        }
        try? FileManager.default.removeItem(at: wavURL)
        return m4aURL
    }
}

/// The per-episode provenance record written next to its script and audio.
/// Encoded rather than string-interpolated so a value containing a quote
/// can't produce a malformed manifest.
struct EpisodeManifest: Codable, Sendable {
    var schemaVersion = 1
    var generator = "KokoroTwoHost"
    var voices: [String: String]
    var sync = "not-transferred"

    init(voices: (hostA: String, hostB: String)) {
        self.voices = ["HOST_A": voices.hostA, "HOST_B": voices.hostB]
    }

    func encoded() throws -> Data { try JSONEncoder().encode(self) }
}

enum KokoroEpisodeRenderer {
    static func render(
        script: String,
        to outputURL: URL,
        pythonURL: URL,
        modelDirectory: URL,
        voices: (hostA: String, hostB: String) = ("af_bella", "am_michael"),
        progress: (@Sendable (KokoroRenderBackend) -> Void)? = nil
    ) async throws -> TimeInterval {
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else { throw KokoroRendererError.runtimeMissing }
        guard let rendererURL = Bundle.main.url(forResource: "KokoroRenderer", withExtension: "py") else { throw KokoroRendererError.rendererMissing }
        // Staged in the temp directory, not the episode directory: it's a
        // duplicate of script.txt that the library neither tracks nor
        // cleans up, so writing it alongside the episode just left a stale
        // copy behind after every render.
        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("readerflow-dialogue-\(UUID().uuidString).txt")
        try script.write(to: inputURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: inputURL) }
        try? FileManager.default.removeItem(at: outputURL)
        // MPS is not the default: measured against ReaderFlow's own
        // generated episode scripts, CPU renders faster despite MPS winning
        // on synthetic benchmarks (see experiments/kokoro-mps-spike).
        progress?(.cpu)
        try await run(
            executable: pythonURL,
            arguments: arguments(renderer: rendererURL, input: inputURL, output: outputURL, device: "cpu", voices: voices),
            environment: ["HF_HOME": modelDirectory.path]
        )
        let audio = try AVAudioFile(forReading: outputURL)
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        guard duration > 0 else { throw KokoroRendererError.emptyAudio }
        return duration
    }

    private static func arguments(renderer: URL, input: URL, output: URL, device: String, voices: (hostA: String, hostB: String)) -> [String] {
        [renderer.path, "--input", input.path, "--output", output.path, "--host-a", voices.hostA, "--host-b", voices.hostB, "--device", device]
    }

    private static func run(executable: URL, arguments: [String], environment: [String: String]) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, replacement in replacement }
        let output = Pipe(); let errors = Pipe()
        process.standardOutput = output; process.standardError = errors

        // Both pipes must be drained *while* the renderer runs. Kokoro and
        // Misaki can emit more warning text than a pipe buffer holds; if
        // nothing reads until termination, the child blocks forever on a
        // full pipe and the render hangs with no way out.
        let collected = RendererErrorOutput()
        output.fileHandleForReading.readabilityHandler = { _ = $0.availableData }
        errors.fileHandleForReading.readabilityHandler = { collected.append($0.availableData) }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let state = RendererProcessState(continuation: continuation)
                process.terminationHandler = { process in
                    output.fileHandleForReading.readabilityHandler = nil
                    errors.fileHandleForReading.readabilityHandler = nil
                    if process.terminationStatus == 0 { state.finish(.success(())) }
                    else { state.finish(.failure(KokoroRendererError.renderFailed(collected.text))) }
                }
                do { try process.run() }
                catch {
                    output.fileHandleForReading.readabilityHandler = nil
                    errors.fileHandleForReading.readabilityHandler = nil
                    state.finish(.failure(error))
                }
            }
        } onCancel: {
            // Without this a quit or cancelled render orphans the Python
            // child, which keeps consuming CPU with nowhere to deliver audio.
            process.terminate()
        }
    }
}

/// Accumulates the renderer's stderr from the pipe's background queue,
/// keeping only the tail so a warning flood can't grow without bound.
private final class RendererErrorOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private static let maximumBytes = 8_192

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.lock()
        data.append(newData)
        if data.count > Self.maximumBytes { data.removeFirst(data.count - Self.maximumBytes) }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private final class RendererProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

enum KokoroRendererError: LocalizedError {
    case runtimeMissing, rendererMissing, emptyAudio, renderFailed(String)

    var errorDescription: String? {
        switch self {
        case .runtimeMissing: return "ReaderFlow’s local Kokoro runtime is unavailable. Re-run Local AI setup."
        case .rendererMissing: return "ReaderFlow’s Kokoro renderer was not included in this build."
        case .emptyAudio: return "Kokoro did not produce playable audio."
        case .renderFailed: return "Kokoro could not render this dialogue. Try a shorter draft or run it again."
        }
    }
}

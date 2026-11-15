import CryptoKit
import Foundation
import Observation
#if !READERFLOW_APP
import ReaderFlowEpisodeLibrary
#endif

/// Owns the local model files rather than relying on a browser, a Python
/// environment, or an account token. The inference adapters deliberately live
/// behind a separate boundary: a completed download is never treated as proof
/// that a model is usable.
@MainActor
@Observable
final class LocalAISetup {
    enum InstallState: Equatable {
        case checking
        case notInstalled
        case downloading(name: String, completed: Int64, total: Int64?)
        case ready
        case failed(String)
    }

    struct Model: Sendable {
        let id: String
        let displayName: String
        let repository: String
        let detail: String
    }

    nonisolated static let qwen = Model(
        id: "qwen3-4b-4bit",
        displayName: "Qwen3 4B (4-bit)",
        repository: "mlx-community/Qwen3-4B-4bit",
        detail: "Creates the source-grounded two-host conversation locally."
    )
    nonisolated static let kokoro = Model(
        id: "kokoro-82m",
        displayName: "Kokoro voices", 
        repository: "hexgrad/Kokoro-82M",
        detail: "Renders the two hosts as local expressive audio."
    )

    private(set) var qwenState: InstallState = .checking
    private(set) var kokoroState: InstallState = .checking
    private(set) var isInstalling = false

    /// Both models downloaded and verified — the precondition for generating
    /// anything. Lives here rather than in each view that gates on it.
    var isReady: Bool {
        if case .ready = qwenState, case .ready = kokoroState { return true }
        return false
    }

    func refresh() {
        qwenState = isComplete(Self.qwen) ? .ready : .notInstalled
        kokoroState = isComplete(Self.kokoro) ? .ready : .notInstalled
    }

    func installRecommendedModels() async {
        guard !isInstalling else { return }
        isInstalling = true
        defer { isInstalling = false }
        await install(Self.qwen)
        guard case .ready = qwenState else { return }
        await install(Self.kokoro)
    }

    var generationStatus: String {
        switch (qwenState, kokoroState) {
        case (.ready, .ready):
            return "Local models are downloaded. The native Qwen + Kokoro runtime is the next feasibility checkpoint."
        case (.downloading(let name, _, _), _), (_, .downloading(let name, _, _)):
            return "Downloading \(name) to this Mac. Large model files may take a few minutes; ReaderFlow verifies each file before it marks setup complete."
        case (.failed(let message), _), (_, .failed(let message)):
            return message
        default:
            return "Set up local AI once. ReaderFlow will download public model files to this Mac; no API key is involved."
        }
    }

    private func install(_ model: Model) async {
        set(.downloading(name: model.displayName, completed: 0, total: nil), for: model)
        do {
            let destination = try modelDirectory(for: model)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let files = try await HuggingFaceSnapshot.files(for: model.repository)
            guard !files.isEmpty else { throw SetupError.noFiles(model.displayName) }
            let total = files.compactMap(\.size).reduce(0, +)
            var completed: Int64 = 0
            for file in files {
                let target = destination.appendingPathComponent(file.path)
                if FileManager.default.fileExists(atPath: target.path), try Self.matchesChecksum(target, expected: file.sha256) {
                    completed += file.size ?? 0
                    continue
                }
                set(.downloading(name: model.displayName, completed: completed, total: total == 0 ? nil : total), for: model)
                let completedBeforeFile = completed
                try await Self.download(file, from: model.repository, to: target) { [weak self] written in
                    Task { @MainActor in self?.set(.downloading(name: model.displayName, completed: completedBeforeFile + written, total: total == 0 ? nil : total), for: model) }
                }
                completed += file.size ?? 0
            }
            try Data("complete\n".utf8).write(to: destination.appendingPathComponent(".readerflow-install"), options: .atomic)
            set(.ready, for: model)
        } catch {
            set(.failed("Could not download \(model.displayName): \(error.localizedDescription)"), for: model)
        }
    }

    private func set(_ state: InstallState, for model: Model) {
        if model.id == Self.qwen.id { qwenState = state } else { kokoroState = state }
    }

    private func isComplete(_ model: Model) -> Bool {
        (try? modelDirectory(for: model).appendingPathComponent(".readerflow-install").checkResourceIsReachable()) ?? false
    }

    private nonisolated func modelDirectory(for model: Model) throws -> URL {
        let root = try EpisodeLibraryStore.defaultRootURL().deletingLastPathComponent().appendingPathComponent("Models", isDirectory: true)
        return root.appendingPathComponent(model.id, isDirectory: true)
    }

    // Pure path computations with no actor-isolated state, so generation work
    // running in a background Task (see `LibraryViewModel.startRendering`) can
    // call these without hopping back to the main actor.
    nonisolated func qwenModelDirectory() throws -> URL { try modelDirectory(for: Self.qwen) }
    nonisolated func kokoroModelDirectory() throws -> URL { try modelDirectory(for: Self.kokoro) }

    nonisolated func kokoroPythonURL() throws -> URL {
        let root = try EpisodeLibraryStore.defaultRootURL().deletingLastPathComponent()
        return root.appendingPathComponent("Runtime/kokoro-venv/bin/python")
    }

    /// Hashes in chunks rather than via `Data(contentsOf:)`, which would pull
    /// the entire file into memory — a multi-gigabyte spike for the Qwen
    /// weights, paid on every install and every verification pass.
    private static func matchesChecksum(_ url: URL, expected: String?) throws -> Bool {
        guard let expected else { return true }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined() == expected.lowercased()
    }

    private static func download(_ file: HuggingFaceSnapshot.File, from repository: String, to target: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = target.appendingPathExtension("download")
        try? FileManager.default.removeItem(at: temporary)
        let url = URL(string: "https://huggingface.co/\(repository)/resolve/main/\(file.path)")!
        // Reports bytes as they arrive. `URLSession.download(for:)` surfaces
        // nothing until the file completes, which left the multi-gigabyte
        // model download sitting at one number for minutes and then jumping.
        let downloadedFile = try await ProgressReportingDownloader(onProgress: progress).download(from: url)
        defer { try? FileManager.default.removeItem(at: downloadedFile) }
        try FileManager.default.copyItem(at: downloadedFile, to: temporary)
        guard try matchesChecksum(temporary, expected: file.sha256) else { throw SetupError.checksumFailed(file.path) }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temporary, to: target)
    }
}

/// Bridges `URLSessionDownloadDelegate`'s byte-level progress callbacks into
/// async/await, so a long model download can report continuously.
private final class ProgressReportingDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?

    init(onProgress: @escaping @Sendable (Int64) -> Void) {
        self.onProgress = onProgress
        super.init()
    }

    func download(from url: URL) async throws -> URL {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock(); self.continuation = continuation; lock.unlock()
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse, (200 ... 299).contains(response.statusCode) else {
            finish(.failure(SetupError.downloadFailed(downloadTask.originalRequest?.url?.lastPathComponent ?? "model file")))
            return
        }
        // The delegate's file is deleted as soon as this returns, so it has
        // to be moved synchronously rather than handed off to the caller.
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            finish(.success(staged))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        finish(.failure(error))
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private enum SetupError: LocalizedError {
    case noFiles(String), downloadFailed(String), checksumFailed(String)
    var errorDescription: String? {
        switch self {
        case .noFiles(let name): "No downloadable files were published for \(name)."
        case .downloadFailed(let path): "The download for \(path) did not complete."
        case .checksumFailed(let path): "The integrity check failed for \(path)."
        }
    }
}

private enum HuggingFaceSnapshot {
    struct File: Decodable, Sendable {
        struct LFS: Decodable, Sendable { let oid: String?; let size: Int64? }
        let rfilename: String
        let lfs: LFS?
        var path: String { rfilename }
        var sha256: String? { lfs?.oid }
        var size: Int64? { lfs?.size }
    }
    private struct Response: Decodable { let siblings: [File] }

    static func files(for repository: String) async throws -> [File] {
        let url = URL(string: "https://huggingface.co/api/models/\(repository)?blobs=true")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else { throw SetupError.downloadFailed(repository) }
        return try JSONDecoder().decode(Response.self, from: data).siblings.filter {
            !$0.path.hasPrefix(".") && !$0.path.hasSuffix(".md") && $0.path != "LICENSE"
        }
    }
}

import AVFoundation
import Foundation

public enum EpisodeLibraryError: Error, LocalizedError { case duplicateID, episodeNotFound, unsafeArtifactPath; public var errorDescription: String? { switch self { case .duplicateID: "An episode with this identifier already exists."; case .episodeNotFound: "The episode was not found in this library."; case .unsafeArtifactPath: "The episode contains an unsafe artifact path." } } }

/// The only owner of the episode index and per-episode artifact directories.
/// Generation writes artifacts first then calls `upsert`; a player only
/// reads episode fields.
///
/// The index file is shared across OS processes — a second launch of the
/// app, or the `--generate-url` CLI path used for testing, both read and
/// write the same file. This actor only serializes access *within* one
/// process; every mutation goes through `NSFileCoordinator` so a second
/// process can't silently clobber this one's write with a stale full-file
/// overwrite. Verified empirically: two processes racing 25 coordinated
/// read-modify-writes each against the same file lost zero updates.
public actor EpisodeLibraryStore {
    private let fileManager: FileManager
    private let rootURL: URL
    private let indexURL: URL
    /// A cache of the last state this instance itself wrote or read, used
    /// for fast reads (`allEpisodes`, `audioURL`, ...). Every *write* re-reads
    /// the authoritative on-disk state under coordination first, so this
    /// cache being briefly stale relative to another process never causes a
    /// lost update — only a momentarily stale read, corrected on this
    /// instance's next mutation or relaunch.
    private var episodes: [Episode] = []

    public init(rootURL: URL, fileManager: FileManager = .default) throws {
        self.rootURL = rootURL.standardizedFileURL
        self.indexURL = rootURL.appendingPathComponent("episode-library.json")
        self.fileManager = fileManager
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        episodes = try Self.coordinatedRead(at: indexURL, fileManager: fileManager)
    }

    public func allEpisodes() -> [Episode] { episodes.sorted { $0.createdAt > $1.createdAt } }
    public func episode(id: UUID) -> Episode? { episodes.first { $0.id == id } }

    public func upsert(_ episode: Episode) throws {
        try validate(episode)
        try mutate { current in
            if let index = current.firstIndex(where: { $0.id == episode.id }) { current[index] = episode }
            else { current.append(episode) }
        }
    }

    public func updatePlaybackPosition(for id: UUID, to position: TimeInterval) throws {
        try mutate { current in
            guard let index = current.firstIndex(where: { $0.id == id }) else { throw EpisodeLibraryError.episodeNotFound }
            current[index].playbackPosition = max(0, position)
        }
    }

    /// Resolves an episode's audio only after applying the same per-episode path validation used by all library mutations.
    public func audioURL(for id: UUID) throws -> URL { guard let episode = episodes.first(where: { $0.id == id }) else { throw EpisodeLibraryError.episodeNotFound }; return try resolvedArtifactURL(episode.audioPath, episodeID: episode.id) }
    /// Reads the saved script text with the same per-episode path validation used by all library mutations.
    public func scriptText(for id: UUID) throws -> String { guard let episode = episodes.first(where: { $0.id == id }) else { throw EpisodeLibraryError.episodeNotFound }; let url = try resolvedArtifactURL(episode.scriptPath, episodeID: episode.id); return try String(contentsOf: url, encoding: .utf8) }

    @discardableResult
    public func refreshRecoveryState(for id: UUID) throws -> Episode {
        try mutate { current in
            guard let index = current.firstIndex(where: { $0.id == id }) else { throw EpisodeLibraryError.episodeNotFound }
            current[index] = try self.recoveryStateApplied(to: current[index])
            return current[index]
        }
    }

    /// Refreshes every episode's recovery state with a single disk write instead of one per episode.
    public func refreshRecoveryStateForAllEpisodes() throws -> [Episode] {
        try mutate { current in
            for index in current.indices { current[index] = try self.recoveryStateApplied(to: current[index]) }
        }
        return allEpisodes()
    }

    /// Deletes exactly `<library root>/episodes/<episode ID>` after verifying all paths belong there.
    public func delete(id: UUID) throws {
        try mutate { current in
            guard let episode = current.first(where: { $0.id == id }) else { throw EpisodeLibraryError.episodeNotFound }
            try self.validate(episode)
            let directory = self.rootURL.appendingPathComponent("episodes", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
            if self.fileManager.fileExists(atPath: directory.path) { try self.fileManager.removeItem(at: directory) }
            current.removeAll { $0.id == id }
        }
    }

    public static func defaultRootURL(fileManager: FileManager = .default) throws -> URL { try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("ReaderFlow", isDirectory: true).appendingPathComponent("EpisodeLibrary", isDirectory: true) }

    private func recoveryStateApplied(to episode: Episode) throws -> Episode {
        var episode = episode
        let audioURL = try resolvedArtifactURL(episode.audioPath, episodeID: episode.id)
        let scriptURL = try resolvedArtifactURL(episode.scriptPath, episodeID: episode.id)
        let manifestURL = try resolvedArtifactURL(episode.artifactManifestPath, episodeID: episode.id)
        if !fileManager.fileExists(atPath: audioURL.path) { episode.lifecycle = .audioUnavailable; episode.recoveryError = .audioMissing }
        else if !fileManager.isReadableFile(atPath: audioURL.path) || !isDecodableAudio(at: audioURL) { episode.lifecycle = .audioUnavailable; episode.recoveryError = .audioUnreadable }
        else if !fileManager.fileExists(atPath: scriptURL.path) || !fileManager.fileExists(atPath: manifestURL.path) { episode.lifecycle = .failed; episode.recoveryError = .artifactMissing }
        else { episode.lifecycle = .ready; episode.recoveryError = nil }
        return episode
    }

    /// Applies `change` to the freshest on-disk state and writes the result
    /// back, all inside one exclusive cross-process file-coordination claim,
    /// then updates the in-memory cache to match. `change` reading and
    /// writing happen atomically as far as any other coordinated writer on
    /// this file is concerned.
    @discardableResult
    private func mutate<T>(_ change: @escaping (inout [Episode]) throws -> T) throws -> T {
        let fileManager = self.fileManager
        let box = CoordinationBox<([Episode], T)> { url in
            var current = try Self.decodeIndex(at: url, fileManager: fileManager)
            let value = try change(&current)
            try JSONEncoder().encode(current).write(to: url, options: .atomic)
            return (current, value)
        }
        var coordinatorError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: indexURL, options: [], error: &coordinatorError) { url in
            box.run(url)
        }
        if let coordinatorError { throw coordinatorError }
        let (current, value) = try box.result!.get()
        episodes = current
        return value
    }

    private static func coordinatedRead(at url: URL, fileManager: FileManager) throws -> [Episode] {
        let box = CoordinationBox<[Episode]> { url in try decodeIndex(at: url, fileManager: fileManager) }
        var coordinatorError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinatorError) { coordinatedURL in
            box.run(coordinatedURL)
        }
        if let coordinatorError { throw coordinatorError }
        return try box.result!.get()
    }

    private static func decodeIndex(at url: URL, fileManager: FileManager) throws -> [Episode] { guard fileManager.fileExists(atPath: url.path) else { return [] }; return try JSONDecoder().decode([Episode].self, from: Data(contentsOf: url)) }
    private func isDecodableAudio(at url: URL) -> Bool { (try? AVAudioFile(forReading: url)) != nil }
    private func validate(_ episode: Episode) throws { _ = try resolvedArtifactURL(episode.scriptPath, episodeID: episode.id); _ = try resolvedArtifactURL(episode.audioPath, episodeID: episode.id); _ = try resolvedArtifactURL(episode.artifactManifestPath, episodeID: episode.id) }
    private func resolvedArtifactURL(_ path: String, episodeID: UUID) throws -> URL { guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw EpisodeLibraryError.unsafeArtifactPath }; guard path.hasPrefix("episodes/\(episodeID.uuidString)/") else { throw EpisodeLibraryError.unsafeArtifactPath }; let url = rootURL.appendingPathComponent(path).standardizedFileURL; guard url.path.hasPrefix(rootURL.path + "/") else { throw EpisodeLibraryError.unsafeArtifactPath }; return url }
}

/// `NSFileCoordinator`'s accessor closure is `@Sendable`, but the work it
/// runs here (touching this actor's `episodes`, calling actor-isolated
/// helpers) genuinely is not — even though the call is synchronous and
/// single-threaded in practice, which is what makes `@unchecked Sendable`
/// safe here specifically. Same laundering pattern already used for
/// `Process.terminationHandler` in KokoroEpisodeRenderer.
private final class CoordinationBox<R>: @unchecked Sendable {
    private let work: (URL) throws -> R
    private(set) var result: Result<R, Error>?

    init(_ work: @escaping (URL) throws -> R) { self.work = work }
    func run(_ url: URL) { result = Result { try work(url) } }
}

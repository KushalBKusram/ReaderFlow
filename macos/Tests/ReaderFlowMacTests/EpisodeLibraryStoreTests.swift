import Foundation
import XCTest
@testable import ReaderFlowAudioPlayback
@testable import ReaderFlowEpisodeLibrary

final class EpisodeLibraryStoreTests: XCTestCase {
    func testPreservesEpisodesAndPlaybackPositionAcrossStoreInstances() async throws {
        let root = try temporaryRoot(); let store = try EpisodeLibraryStore(rootURL: root); let episode = try makeEpisode(in: root)
        try await store.upsert(episode); try await store.updatePlaybackPosition(for: episode.id, to: 42.5)
        let reopened = try EpisodeLibraryStore(rootURL: root)
        let restored = await reopened.episode(id: episode.id)
        let all = await reopened.allEpisodes()
        XCTAssertEqual(restored?.playbackPosition, 42.5)
        XCTAssertEqual(all.count, 1)
    }

    /// A second store instance stands in for a second process — the CLI
    /// generation path, or the app launched twice — writing to the same
    /// index file. Before mutations re-read fresh state under file
    /// coordination, this pattern silently dropped whichever write
    /// happened first: each instance held its own in-memory snapshot and
    /// `persist()` blindly overwrote the file with it.
    func testConcurrentStoreInstancesDoNotDropEachOthersWrites() async throws {
        let root = try temporaryRoot()
        let storeA = try EpisodeLibraryStore(rootURL: root)
        let storeB = try EpisodeLibraryStore(rootURL: root)
        let episodeA = try makeEpisode(in: root)
        let episodeB = try makeEpisode(in: root)

        try await storeA.upsert(episodeA)
        // storeB loaded before episodeA existed, so its in-memory snapshot
        // is stale at this point — exactly the condition that used to lose
        // episodeA the moment storeB wrote next.
        try await storeB.upsert(episodeB)

        let reopened = try EpisodeLibraryStore(rootURL: root)
        let all = await reopened.allEpisodes()
        XCTAssertEqual(Set(all.map(\.id)), [episodeA.id, episodeB.id])
    }

    func testMissingAudioBecomesSafeRecoveryState() async throws {
        let root = try temporaryRoot(); let store = try EpisodeLibraryStore(rootURL: root); let episode = try makeEpisode(in: root, includeAudio: false)
        try await store.upsert(episode); let refreshed = try await store.refreshRecoveryState(for: episode.id)
        XCTAssertEqual(refreshed.lifecycle, .audioUnavailable); XCTAssertEqual(refreshed.recoveryError, .audioMissing)
    }

    func testInvalidAudioBecomesSafeRecoveryState() async throws {
        let root = try temporaryRoot(); let store = try EpisodeLibraryStore(rootURL: root); let episode = try makeEpisode(in: root)
        try await store.upsert(episode); let refreshed = try await store.refreshRecoveryState(for: episode.id)
        XCTAssertEqual(refreshed.lifecycle, .audioUnavailable); XCTAssertEqual(refreshed.recoveryError, .audioUnreadable)
    }

    func testDeletionOnlyRemovesSelectedEpisodeDirectory() async throws {
        let root = try temporaryRoot(); let store = try EpisodeLibraryStore(rootURL: root); let first = try makeEpisode(in: root); let second = try makeEpisode(in: root)
        try await store.upsert(first); try await store.upsert(second)
        let unrelated = root.appendingPathComponent("unrelated.txt"); try "keep".write(to: unrelated, atomically: true, encoding: .utf8)
        try await store.delete(id: first.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("episodes/\(first.id.uuidString)").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("episodes/\(second.id.uuidString)").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        let remaining = await store.allEpisodes()
        XCTAssertEqual(remaining.map(\.id), [second.id])
    }

    func testRejectsArtifactOutsideItsOwnDirectory() async throws {
        let root = try temporaryRoot(); let store = try EpisodeLibraryStore(rootURL: root); let id = UUID()
        let episode = Episode(title: "Unsafe", displayMetadata: .init(sourceLabel: "Fixture"), scriptPath: "episodes/\(id.uuidString)/script.txt", audioPath: "episodes/another-episode/audio.m4a", artifactManifestPath: "episodes/\(id.uuidString)/manifest.json")
        do { try await store.upsert(episode); XCTFail("Expected unsafe path rejection") } catch EpisodeLibraryError.unsafeArtifactPath { }
    }

    @MainActor
    func testPlayerResumesAndPersistsPausedPosition() async throws {
        let root = try temporaryRoot(); let store = try EpisodeLibraryStore(rootURL: root)
        let episode = try makePlayableEpisode(in: root)
        try await store.upsert(episode); try await store.updatePlaybackPosition(for: episode.id, to: 0.25)
        let player = EpisodePlayer(store: store)
        await player.play(episode)
        XCTAssertEqual(player.state, .playing)
        XCTAssertEqual(player.elapsed, 0.25, accuracy: 0.05)
        await player.seek(to: 0.5)
        await player.pause()
        XCTAssertEqual(player.state, .ready)
        let savedEpisode = await store.episode(id: episode.id)
        XCTAssertEqual(savedEpisode?.playbackPosition ?? -1, 0.5, accuracy: 0.05)
    }

    @MainActor
    func testPlayerCompletionResetsPersistedPosition() async throws {
        let root = try temporaryRoot(); let store = try EpisodeLibraryStore(rootURL: root)
        let episode = try makePlayableEpisode(in: root)
        try await store.upsert(episode); try await store.updatePlaybackPosition(for: episode.id, to: 0.4)
        let player = EpisodePlayer(store: store)
        await player.play(episode)
        player.finishPlayback()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(player.state, .ready)
        XCTAssertEqual(player.elapsed, 0)
        let completedEpisode = await store.episode(id: episode.id)
        XCTAssertEqual(completedEpisode?.playbackPosition, 0)
    }

    @MainActor
    func testPlayerResetsOutOfRangeResumePosition() async throws {
        let root = try temporaryRoot(); let store = try EpisodeLibraryStore(rootURL: root)
        let episode = try makePlayableEpisode(in: root)
        try await store.upsert(episode); try await store.updatePlaybackPosition(for: episode.id, to: 99)
        let player = EpisodePlayer(store: store)
        await player.play(episode)
        XCTAssertEqual(player.elapsed, 0)
        let resetEpisode = await store.episode(id: episode.id)
        XCTAssertEqual(resetEpisode?.playbackPosition, 0)
    }

    @MainActor
    func testPlayerDoesNotOpenUnavailableOrInvalidAudio() async throws {
        let root = try temporaryRoot(); let store = try EpisodeLibraryStore(rootURL: root)
        let missing = try makeEpisode(in: root, includeAudio: false)
        try await store.upsert(missing)
        let player = EpisodePlayer(store: store)
        await player.play(missing)
        XCTAssertEqual(player.state, .unavailable(EpisodeRecoveryError.audioMissing.message))

        let invalid = try makeEpisode(in: root)
        try await store.upsert(invalid)
        await player.play(invalid)
        XCTAssertEqual(player.state, .unavailable(EpisodeRecoveryError.audioUnreadable.message))
    }

    private func temporaryRoot() throws -> URL { let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root }
    private func makeEpisode(in root: URL, includeAudio: Bool = true) throws -> Episode { let id = UUID(); let dir = root.appendingPathComponent("episodes/\(id.uuidString)"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); try "script".write(to: dir.appendingPathComponent("script.txt"), atomically: true, encoding: .utf8); try "{}".write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8); if includeAudio { try Data([0x00]).write(to: dir.appendingPathComponent("audio.m4a")) }; return Episode(id: id, title: "Test", displayMetadata: .init(sourceLabel: "Fixture"), scriptPath: "episodes/\(id.uuidString)/script.txt", audioPath: "episodes/\(id.uuidString)/audio.m4a", artifactManifestPath: "episodes/\(id.uuidString)/manifest.json") }
    private func makePlayableEpisode(in root: URL) throws -> Episode {
        let id = UUID(); let dir = root.appendingPathComponent("episodes/\(id.uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "script".write(to: dir.appendingPathComponent("script.txt"), atomically: true, encoding: .utf8)
        try "{}".write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try makeWAV(duration: 1).write(to: dir.appendingPathComponent("audio.wav"))
        return Episode(id: id, title: "Playable", displayMetadata: .init(sourceLabel: "Fixture"), scriptPath: "episodes/\(id.uuidString)/script.txt", audioPath: "episodes/\(id.uuidString)/audio.wav", artifactManifestPath: "episodes/\(id.uuidString)/manifest.json")
    }
    private func makeWAV(duration: Double) -> Data {
        let sampleRate = 8_000; let samples = Int(Double(sampleRate) * duration); let bytes = samples * 2
        var data = Data("RIFF".utf8); data.appendLE(UInt32(36 + bytes)); data.append(Data("WAVEfmt ".utf8)); data.appendLE(UInt32(16)); data.appendLE(UInt16(1)); data.appendLE(UInt16(1)); data.appendLE(UInt32(sampleRate)); data.appendLE(UInt32(sampleRate * 2)); data.appendLE(UInt16(2)); data.appendLE(UInt16(16)); data.append(Data("data".utf8)); data.appendLE(UInt32(bytes)); data.append(Data(repeating: 0, count: bytes)); return data
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) { var littleEndian = value.littleEndian; Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) } }
}

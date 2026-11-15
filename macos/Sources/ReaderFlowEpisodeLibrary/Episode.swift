import Foundation

/// A durable, provider-agnostic library record. Paths are relative to the library root.
public struct Episode: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID; public var title: String; public var displayMetadata: EpisodeDisplayMetadata; public let createdAt: Date
    public let scriptPath: String; public let audioPath: String; public let artifactManifestPath: String
    public var audioDuration: TimeInterval?; public var playbackPosition: TimeInterval; public var lifecycle: EpisodeLifecycle; public var recoveryError: EpisodeRecoveryError?
    public init(id: UUID = UUID(), title: String, displayMetadata: EpisodeDisplayMetadata, createdAt: Date = .now, scriptPath: String, audioPath: String, artifactManifestPath: String, audioDuration: TimeInterval? = nil, playbackPosition: TimeInterval = 0, lifecycle: EpisodeLifecycle = .ready, recoveryError: EpisodeRecoveryError? = nil) {
        self.id = id; self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled episode" : title; self.displayMetadata = displayMetadata; self.createdAt = createdAt; self.scriptPath = scriptPath; self.audioPath = audioPath; self.artifactManifestPath = artifactManifestPath; self.audioDuration = audioDuration; self.playbackPosition = max(0, playbackPosition); self.lifecycle = lifecycle; self.recoveryError = recoveryError
    }
}
public struct EpisodeDisplayMetadata: Codable, Equatable, Sendable { public var sourceLabel: String; public var summary: String?; public init(sourceLabel: String, summary: String? = nil) { self.sourceLabel = sourceLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Local episode" : sourceLabel; self.summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines) } }
public enum EpisodeLifecycle: String, Codable, Sendable { case ready, audioUnavailable, failed }
/// Intentionally contains no filesystem, provider, or system error details.
public enum EpisodeRecoveryError: String, Codable, Sendable, Equatable { case audioMissing, audioUnreadable, artifactMissing; public var message: String { switch self { case .audioMissing: "Audio is unavailable. Regenerate this episode or remove it from your library."; case .audioUnreadable: "Audio cannot be read. Regenerate this episode or remove it from your library."; case .artifactMissing: "This episode’s local files are incomplete. Regenerate or remove it." } } }

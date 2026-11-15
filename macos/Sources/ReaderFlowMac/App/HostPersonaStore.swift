import Foundation

/// A single host's identity as it exists right now. This is a snapshot, not
/// a log — it gets rewritten after every episode rather than appended to, so
/// personality accumulates in what the two hosts *are* instead of growing an
/// unbounded history that would eventually overwhelm the prompt.
struct HostPersona: Codable, Sendable, Equatable {
    var name: String
    var voice: String
}

struct HostPersonaProfile: Codable, Sendable, Equatable {
    var hostA: HostPersona
    var hostB: HostPersona
    var episodeCount: Int

    /// Before any episode has aired, the hosts start as two distinct but
    /// unnamed people — enough personality to write with immediately, with
    /// room for names and specifics to emerge from what they actually cover.
    static let seed = HostPersonaProfile(
        hostA: HostPersona(name: "Host A", voice: "Naturally curious, enjoys drawing unexpected connections between ideas, and gets visibly excited by a clever detail."),
        hostB: HostPersona(name: "Host B", voice: "A careful, grounded pragmatist who likes concrete examples and gently pressure-tests big claims."),
        episodeCount: 0
    )
}

/// Persists the show's two-host identity across episodes, local-only, like
/// the rest of ReaderFlow's storage — so the hosts' personality is a
/// property of this Mac's show, not of any single episode.
actor HostPersonaStore {
    static let shared = HostPersonaStore()

    private var profile: HostPersonaProfile?

    func current() -> HostPersonaProfile {
        if let profile { return profile }
        let loaded = (try? Self.defaultURL()).flatMap { url in
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(HostPersonaProfile.self, from: $0) }
        } ?? .seed
        profile = loaded
        return loaded
    }

    func update(_ newProfile: HostPersonaProfile) {
        profile = newProfile
        guard let url = try? Self.defaultURL() else { return }
        try? JSONEncoder().encode(newProfile).write(to: url, options: .atomic)
    }

    private static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        let root = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ReaderFlow", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("host-personas.json")
    }
}

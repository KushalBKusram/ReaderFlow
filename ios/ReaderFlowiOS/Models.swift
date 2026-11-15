import Foundation

struct ListenerEpisode: Identifiable, Hashable, Codable {
    enum State: String, Hashable, Codable {
        case ready
        case generating
        case needsAudio
    }

    let id: UUID
    var title: String
    var source: String
    var duration: TimeInterval
    var progress: Double
    var summary: String
    var state: State
    var createdAt: Date
    var audioFilename: String?
}

struct ScriptDraft: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let body: String
    let createdAt: Date
    let isRevised: Bool
}

enum GenerationAvailability: Equatable {
    case ready
    case unavailable(String)
}

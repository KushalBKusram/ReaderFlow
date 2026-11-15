import Foundation

/// Every event is a coarse category plus a timestamp — never article text,
/// scripts, titles, or URLs — so the opt-in log can't leak reading content.
enum DogfoodMetricEvent: String, Codable, Sendable {
    case generationStarted = "generation_started"
    case generationSucceeded = "generation_succeeded"
    case generationFailed = "generation_failed"
    case playbackStarted = "playback_started"
    case playbackCompleted = "playback_completed"
    case episodeDeleted = "episode_deleted"
}

struct DogfoodMetricRecord: Codable, Sendable {
    let timestamp: Date
    let event: DogfoodMetricEvent
    /// A coarse category such as a failure stage or deletion reason — never
    /// free text derived from article content, scripts, or titles.
    let detail: String?
}

/// An opt-in, local-only append log for the dogfood-pilot feasibility gate.
/// Records event categories and timestamps to answer product questions
/// (generations, starts, completions, listening days, conversion, failure
/// rate, abandonment reasons) without ever collecting article or script
/// content. Nothing is written, and no data leaves this Mac, unless
/// `DogfoodMetricsSettings.isEnabled` is true.
actor DogfoodMetricsLog {
    private let fileManager: FileManager
    private let logURL: URL

    static func defaultLogURL(fileManager: FileManager = .default) throws -> URL {
        try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ReaderFlow", isDirectory: true)
            .appendingPathComponent("dogfood-metrics.jsonl")
    }

    init(logURL: URL, fileManager: FileManager = .default) throws {
        self.logURL = logURL
        self.fileManager = fileManager
        try fileManager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func record(_ event: DogfoodMetricEvent, detail: String? = nil) {
        guard DogfoodMetricsSettings.isEnabled else { return }
        guard let line = try? JSONEncoder().encode(DogfoodMetricRecord(timestamp: Date(), event: event, detail: detail)) else { return }
        let entry = line + Data("\n".utf8)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(entry)
        } else {
            try? entry.write(to: logURL)
        }
    }

    /// All recorded events, oldest first — used by the in-app summary so the
    /// user can see exactly what's been logged before ever sharing it.
    func allRecords() -> [DogfoodMetricRecord] {
        guard let data = try? Data(contentsOf: logURL) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(DogfoodMetricRecord.self, from: Data($0)) }
    }

    /// Permanently erases the local log. There is no remote copy to clear.
    func clear() { try? fileManager.removeItem(at: logURL) }
}

/// The opt-in toggle, off by default. No event is written until the user
/// turns this on in Settings; turning it back off stops further writes
/// immediately but leaves any existing local log in place.
enum DogfoodMetricsSettings {
    private static let key = "dogfoodMetricsEnabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

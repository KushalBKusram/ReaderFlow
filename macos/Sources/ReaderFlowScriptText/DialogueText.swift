import Foundation

/// Pure text transforms for generated podcast dialogue: no model, no
/// filesystem, no UI. They live in their own module so they can be unit
/// tested — the executable target can't be imported by tests, and these are
/// exactly the rules whose edge cases (markdown-wrapped speaker labels,
/// last-match-wins boundary search, monologue detection) are easy to get
/// subtly wrong and impossible to eyeball in a generated script.
public enum DialogueText {
    // MARK: - Cleanup

    /// Removes Qwen's optional reasoning trace and normalizes every speaker
    /// label. Applied to raw model output before anything else reads it.
    public static func clean(_ response: String) -> String {
        stripThinking(response)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(normalizeHostLabel)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Qwen3 may emit an internal `<think>` section before its answer. It is
    /// not podcast material and some TTS phonemizers cannot parse it.
    public static func stripThinking(_ text: String) -> String {
        text.replacingOccurrences(of: "(?is)<think>.*?</think>", with: "", options: .regularExpression)
    }

    /// Strips markdown or bullet noise around a speaker label (`**HOST_A:**`,
    /// `- host_a:`) and uppercases it. The renderer only recognizes a bare
    /// `HOST_A:`/`HOST_B:` at the start of a line, so an un-normalized label
    /// silently misattributes that whole turn to whoever spoke previously
    /// rather than failing loudly. Text that merely mentions a label
    /// mid-sentence is left alone.
    public static func normalizeHostLabel(_ rawLine: some StringProtocol) -> String {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard let match = line.range(of: #"HOST_[AB]:"#, options: [.regularExpression, .caseInsensitive]) else { return line }
        let prefix = line[line.startIndex ..< match.lowerBound]
        guard prefix.allSatisfy({ "*_-•> ".contains($0) }) else { return line }
        let tag = line[match].uppercased()
        var rest = line[match.upperBound...].trimmingCharacters(in: .whitespaces)
        while let first = rest.first, "*_".contains(first) { rest.removeFirst() }
        rest = rest.trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? tag : "\(tag) \(rest)"
    }

    // MARK: - Shape checks

    public static func wordCount(_ value: String) -> Int {
        value.split { $0.isWhitespace || $0.isNewline }.count
    }

    public static func containsHostLabel(_ dialogue: String) -> Bool {
        dialogue.contains("HOST_A:") || dialogue.contains("HOST_B:")
    }

    /// The speaking order, one entry per labelled turn.
    public static func hostSequence(_ dialogue: String) -> [Character] {
        dialogue.split(separator: "\n").compactMap { line in
            guard let match = line.range(of: #"^HOST_[AB]:"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
            return line[match].uppercased().contains("A") ? "A" : "B"
        }
    }

    /// True when the script isn't really a two-way exchange: too few turns to
    /// be a conversation, or one host holding the floor for more than a third
    /// of it in a row.
    public static func isPoorlyAlternating(_ dialogue: String) -> Bool {
        let hosts = hostSequence(dialogue)
        guard hosts.count >= 4 else { return true }
        var longestRun = 1
        var currentRun = 1
        for index in 1 ..< hosts.count {
            if hosts[index] == hosts[index - 1] { currentRun += 1; longestRun = max(longestRun, currentRun) }
            else { currentRun = 1 }
        }
        return longestRun > max(4, hosts.count / 3)
    }

    // MARK: - Source shaping

    /// Truncates at the last sentence boundary within the limit rather than
    /// mid-sentence, unless that would discard more than 20% of the allotted
    /// context — in which case a hard cut preserves more content.
    public static func truncateAtSentenceBoundary(_ text: String, maximumCharacters: Int) -> String {
        guard text.count > maximumCharacters else { return text }
        let cutoff = text.index(text.startIndex, offsetBy: maximumCharacters)
        let truncated = String(text[..<cutoff])
        let minimumAcceptableCount = Int(Double(maximumCharacters) * 0.8)
        if let lastBoundary = lastRegexMatch(of: #"[.!?]\s"#, in: truncated),
           truncated.distance(from: truncated.startIndex, to: lastBoundary.upperBound) >= minimumAcceptableCount {
            return String(truncated[..<lastBoundary.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return truncated.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits a long source at paragraph or sentence boundaries near each
    /// `maximumCharacters` mark, so a section handed to the summarizer never
    /// begins or ends mid-sentence.
    public static func splitIntoSections(_ text: String, maximumCharacters: Int) -> [String] {
        var sections: [String] = []
        var remaining = text
        while !remaining.isEmpty {
            guard remaining.count > maximumCharacters else {
                sections.append(remaining)
                break
            }
            let cutoff = remaining.index(remaining.startIndex, offsetBy: maximumCharacters)
            let window = String(remaining[..<cutoff])
            let boundary = lastRegexMatch(of: #"\n\n"#, in: window) ?? lastRegexMatch(of: #"[.!?]\s"#, in: window)
            if let boundary {
                let boundaryOffset = window.distance(from: window.startIndex, to: boundary.upperBound)
                let splitIndex = remaining.index(remaining.startIndex, offsetBy: boundaryOffset)
                sections.append(String(remaining[..<splitIndex]))
                remaining = String(remaining[splitIndex...])
            } else {
                sections.append(window)
                remaining = String(remaining[cutoff...])
            }
        }
        return sections.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// `String.range(of:options:)` does not honor `.backwards` for a
    /// `.regularExpression` pattern — it silently returns the *first* match
    /// regardless of that option, which quietly broke both callers above.
    /// This finds the true last match.
    public static func lastRegexMatch(of pattern: String, in text: String) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.matches(in: text, range: range).last else { return nil }
        return Range(match.range, in: text)
    }
}

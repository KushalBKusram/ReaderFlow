import XCTest
@testable import ReaderFlowScriptText

/// These cover the rules that are invisible in a finished episode: a
/// mis-normalized speaker label silently reassigns a turn to the wrong voice,
/// and a bad boundary search silently truncates or over-chunks the source.
/// Both were verified by hand during development; these pin them down.
final class DialogueTextTests: XCTestCase {

    // MARK: - Speaker labels

    func testStripsMarkdownAroundHostLabel() {
        XCTAssertEqual(DialogueText.normalizeHostLabel("**HOST_A:** Hello there"), "HOST_A: Hello there")
        XCTAssertEqual(DialogueText.normalizeHostLabel("- host_b: hi"), "HOST_B: hi")
        XCTAssertEqual(DialogueText.normalizeHostLabel("> _HOST_A:_ padded"), "HOST_A: padded")
    }

    func testLeavesAlreadyCleanLabelUnchanged() {
        XCTAssertEqual(DialogueText.normalizeHostLabel("HOST_A: fine"), "HOST_A: fine")
    }

    /// A label appearing mid-sentence is prose, not a speaker change;.
    /// rewriting it would invent a turn that the renderer then attributes to
    /// a different voice.
    func testDoesNotRewriteLabelMentionedMidSentence() {
        let line = "He said HOST_A: nonsense"
        XCTAssertEqual(DialogueText.normalizeHostLabel(line), line)
    }

    func testLeavesContinuationLineUnchanged() {
        XCTAssertEqual(DialogueText.normalizeHostLabel("just more words"), "just more words")
    }

    func testCleanRemovesThinkingTraceAndNormalizes() {
        let raw = "<think>\nplanning the episode\n</think>\n**HOST_A:** One\nHOST_B: Two"
        XCTAssertEqual(DialogueText.clean(raw), "HOST_A: One\nHOST_B: Two")
    }

    // MARK: - Alternation

    func testAlternatingDialogueIsAccepted() {
        let dialogue = (1 ... 10)
            .map { $0.isMultiple(of: 2) ? "HOST_A: line \($0)" : "HOST_B: line \($0)" }
            .joined(separator: "\n")
        XCTAssertFalse(DialogueText.isPoorlyAlternating(dialogue))
    }

    func testOneHostMonologuingIsRejected() {
        let dialogue = (1 ... 10)
            .map { $0 < 8 ? "HOST_A: line \($0)" : "HOST_B: line \($0)" }
            .joined(separator: "\n")
        XCTAssertTrue(DialogueText.isPoorlyAlternating(dialogue))
    }

    func testTooFewTurnsIsRejected() {
        XCTAssertTrue(DialogueText.isPoorlyAlternating("HOST_A: one\nHOST_B: two"))
    }

    func testHostSequenceIgnoresUnlabelledLines() {
        let dialogue = "HOST_A: one\nstray continuation\nHOST_B: two"
        XCTAssertEqual(DialogueText.hostSequence(dialogue), ["A", "B"])
    }

    // MARK: - Boundary search

    /// `range(of:options:)` silently ignores `.backwards` for regex patterns
    /// and returns the *first* match; this is the regression guard for that.
    func testLastRegexMatchFindsFinalOccurrenceNotFirst() {
        let text = "AAA. BBB. CCC. DDD."
        let match = DialogueText.lastRegexMatch(of: #"[.!?]\s"#, in: text)
        let offset = try? XCTUnwrap(match).lowerBound
        XCTAssertEqual(offset.map { text.distance(from: text.startIndex, to: $0) }, 13)
    }

    func testTruncateStopsOnSentenceBoundary() {
        let text = "This is sentence one, padded a bit to reach length. This is sentence two also padded here nicely. Trailing fragment"
        let truncated = DialogueText.truncateAtSentenceBoundary(text, maximumCharacters: 110)
        XCTAssertTrue(truncated.hasSuffix("."), "expected a clean sentence end, got: \(truncated)")
        XCTAssertLessThanOrEqual(truncated.count, 110)
    }

    /// When the only boundary sits far below the limit, a hard cut keeps more
    /// usable context than collapsing to that early boundary.
    func testTruncateFallsBackToHardCutWhenBoundaryTooEarly() {
        let text = "Short. " + String(repeating: "x", count: 300)
        let truncated = DialogueText.truncateAtSentenceBoundary(text, maximumCharacters: 200)
        XCTAssertEqual(truncated.count, 200)
    }

    func testShortTextIsReturnedUntouched() {
        XCTAssertEqual(DialogueText.truncateAtSentenceBoundary("brief", maximumCharacters: 100), "brief")
    }

    // MARK: - Sectioning

    func testSectionsFillUpToTheLimitAndPreserveContent() {
        let paragraph = String(repeating: "Sentence about the subject matter. ", count: 30).trimmingCharacters(in: .whitespaces)
        let text = Array(repeating: paragraph, count: 8).joined(separator: "\n\n")
        let sections = DialogueText.splitIntoSections(text, maximumCharacters: 6_000)

        XCTAssertGreaterThan(sections.count, 1)
        for section in sections {
            XCTAssertLessThanOrEqual(section.count, 6_000)
        }
        // Each section should be substantial rather than collapsing to one
        // paragraph per section, which is what the earlier `.backwards` bug did.
        for section in sections.dropLast() {
            XCTAssertGreaterThan(section.count, 3_000, "sections are splitting far too early")
        }
        let reassembled = sections.joined(separator: " ").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let original = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        XCTAssertEqual(reassembled, original, "splitting must not drop or duplicate content")
    }

    func testTextBelowLimitStaysOneSection() {
        XCTAssertEqual(DialogueText.splitIntoSections("Just a little text.", maximumCharacters: 6_000), ["Just a little text."])
    }

    func testWordCountIgnoresExtraWhitespace() {
        XCTAssertEqual(DialogueText.wordCount("  one   two\n\nthree  "), 3)
    }
}

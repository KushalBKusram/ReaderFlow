import Foundation
import PDFKit

enum StudioError: LocalizedError {
    case emptySource

    var errorDescription: String? {
        switch self {
        case .emptySource: "Paste or import an article before creating an episode."
        }
    }
}

enum ArticleInputError: LocalizedError {
    case unsupportedResponse
    case pageTooLarge
    case noReadableText
    case pdfUnreadable

    var errorDescription: String? {
        switch self {
        case .unsupportedResponse: "ReaderFlow could not retrieve a readable public article from that link. It may require sign-in, be paywalled, or not be an HTML page."
        case .pageTooLarge: "That page is too large to process. Paste the article text instead."
        case .noReadableText: "ReaderFlow could not find readable article text on that page. Paste the article text instead."
        case .pdfUnreadable: "ReaderFlow could not read text from that PDF. It may be a scanned image without a selectable text layer."
        }
    }
}

/// Extracts text locally via PDFKit — no upload, no OCR service. A scanned
/// PDF with no text layer yields no per-page string and is reported as
/// unreadable rather than silently producing an empty episode.
enum PDFArticleExtractor {
    static func extractText(from url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else { throw ArticleInputError.pdfUnreadable }
        let text = (0 ..< document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 160 else { throw ArticleInputError.pdfUnreadable }
        return text
    }
}

/// Resolves either pasted text or a public web URL. The ephemeral request has no
/// cookies, credentials, or cache, and never attempts to bypass restrictions.
enum ArticleInputResolver {
    private static let maximumBytes = 3_000_000

    /// One shared ephemeral session. A `URLSession` created per fetch is
    /// retained by the system until it is explicitly invalidated, so the
    /// previous per-call session leaked one on every article resolved.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    static func resolve(_ input: String) async throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StudioError.emptySource }
        guard let url = publicWebURL(from: trimmed) else { return trimmed }
        var request = URLRequest(url: url)
        request.setValue("ReaderFlow/0.1 (local article reader)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else { throw ArticleInputError.unsupportedResponse }
        guard data.count <= maximumBytes else { throw ArticleInputError.pageTooLarge }
        if let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(), !type.contains("text/html") && !type.contains("application/xhtml") { throw ArticleInputError.unsupportedResponse }
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw ArticleInputError.unsupportedResponse }
        let text = HTMLReadableTextExtractor.extract(from: html)
        guard text.count >= 160 else { throw ArticleInputError.noReadableText }
        return text
    }

    static func publicWebURL(from input: String) -> URL? {
        guard !input.contains(where: \.isWhitespace), let url = URL(string: input), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }
}

enum HTMLReadableTextExtractor {
    static func extract(from html: String) -> String {
        let withoutNonContent = replace("(?is)<(script|style|noscript|svg|nav|footer|aside|form|header)[^>]*>.*?</\\1>", in: html, with: " ")
        let container = firstCapture("(?is)<article[^>]*>(.*?)</article>", in: withoutNonContent) ?? firstCapture("(?is)<main[^>]*>(.*?)</main>", in: withoutNonContent) ?? firstCapture("(?is)<body[^>]*>(.*?)</body>", in: withoutNonContent) ?? withoutNonContent
        let blocks = captures("(?is)<(?:p|h1|h2|h3|li|blockquote)[^>]*>(.*?)</(?:p|h1|h2|h3|li|blockquote)>", in: container).map(text).filter { $0.count > 24 }
        let result = blocks.isEmpty ? text(container) : blocks.joined(separator: "\n\n")
        return replace("\\n{3,}", in: result, with: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func text(_ html: String) -> String {
        let withBreaks = replace("(?is)</?(p|div|section|article|main|h[1-6]|li|br|blockquote)[^>]*>", in: html, with: "\n")
        let noTags = replace("(?is)<[^>]+>", in: withBreaks, with: " ")
        let entities = noTags.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        return replace("[ \\t]+", in: entities, with: " ").replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstCapture(_ pattern: String, in value: String) -> String? { captures(pattern, in: value).first }
    private static func captures(_ pattern: String, in value: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: value) else { return nil }
            return String(value[range])
        }
    }
    private static func replace(_ pattern: String, in value: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        return expression.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: replacement)
    }
}

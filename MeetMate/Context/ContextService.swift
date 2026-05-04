import Foundation
import Combine
#if canImport(PDFKit)
import PDFKit
#endif

/// Manages pre-meeting context: free-form notes, fetched URLs, and dropped PDFs.
/// Provides a formatted context string for injection into LLM prompts.
@MainActor
final class ContextService: ObservableObject {
    @Published var freeformText: String = ""
    @Published var fetchedURLText: String = ""
    @Published var pdfText: String = ""
    @Published private(set) var isFetching = false
    @Published private(set) var fetchError: String?

    /// Max token budget for context injection (rough: 1 token ≈ 4 chars).
    private let maxChars = 12_000

    /// Combined context for prompt injection. Empty string if nothing set.
    var combinedContext: String {
        var parts: [String] = []
        if !freeformText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Notes:\n\(freeformText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if !fetchedURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Reference material:\n\(fetchedURLText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if !pdfText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Document:\n\(pdfText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        guard !parts.isEmpty else { return "" }
        let full = parts.joined(separator: "\n\n---\n\n")
        return truncateToTokenBudget(full)
    }

    /// Whether the context budget is near the limit.
    var isNearLimit: Bool {
        combinedContext.count > Int(Double(maxChars) * 0.85)
    }

    /// Approximate token count (chars / 4).
    var approximateTokens: Int {
        combinedContext.count / 4
    }

    /// Whether any context has been provided.
    var hasContext: Bool {
        !combinedContext.isEmpty
    }

    // MARK: - URL fetch

    func fetchURL(_ urlString: String) async {
        guard let url = URL(string: urlString), url.scheme == "https" || url.scheme == "http" else {
            fetchError = "Invalid URL"
            return
        }

        isFetching = true
        fetchError = nil
        defer { isFetching = false }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                fetchError = "HTTP \(code)"
                return
            }
            guard let html = String(data: data, encoding: .utf8) else {
                fetchError = "Could not decode response"
                return
            }
            fetchedURLText = stripHTMLToReadableText(html)
            print("[Context] fetched \(url.host ?? ""), \(fetchedURLText.count) chars")
        } catch {
            fetchError = error.localizedDescription
        }
    }

    // MARK: - PDF extraction

    func extractPDF(from url: URL) {
        #if canImport(PDFKit)
        guard let document = PDFDocument(url: url) else {
            fetchError = "Could not open PDF"
            return
        }
        var text = ""
        for i in 0..<document.pageCount {
            if let page = document.page(at: i), let pageText = page.string {
                text += pageText + "\n\n"
            }
        }
        pdfText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[Context] extracted PDF, \(pdfText.count) chars from \(document.pageCount) pages")
        #else
        fetchError = "PDF not supported on this platform"
        #endif
    }

    // MARK: - Reset

    func clear() {
        freeformText = ""
        fetchedURLText = ""
        pdfText = ""
        fetchError = nil
        userVocabulary = []
    }

    // MARK: - Vocabulary

    /// User-edited vocabulary terms (persisted per meeting).
    @Published var userVocabulary: [String] = []

    /// Auto-extracted terms from context. Recomputed on access.
    var extractedVocabulary: [String] {
        VocabularyExtractor.extract(from: combinedContext)
    }

    /// Final merged vocabulary: user terms + auto-extracted.
    var mergedVocabulary: [String] {
        VocabularyExtractor.merge(extracted: extractedVocabulary, userEdited: userVocabulary)
    }

    /// Add a user term to the vocabulary list.
    func addVocabularyTerm(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !userVocabulary.contains(trimmed) else { return }
        userVocabulary.append(trimmed)
    }

    /// Remove a user term.
    func removeVocabularyTerm(_ term: String) {
        userVocabulary.removeAll { $0 == term }
    }

    // MARK: - Persistence

    func persist(to storage: SessionStorage) {
        guard hasContext else { return }
        storage.writeContext(combinedContext)
    }

    // MARK: - Private

    private func truncateToTokenBudget(_ text: String) -> String {
        guard text.count > maxChars else { return text }
        let truncated = String(text.prefix(maxChars))
        return truncated + "\n\n[…truncated — \(text.count - maxChars) chars over budget]"
    }

    private func stripHTMLToReadableText(_ html: String) -> String {
        var text = html
        // Remove script/style blocks
        let blockPatterns = ["<script[^>]*>[\\s\\S]*?</script>", "<style[^>]*>[\\s\\S]*?</style>"]
        for pattern in blockPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            }
        }
        // Replace block elements with newlines
        let blockTags = ["</p>", "</div>", "</h1>", "</h2>", "</h3>", "</h4>", "</li>", "<br", "</tr>"]
        for tag in blockTags {
            text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }
        // Strip remaining tags
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        // Decode common entities
        let entities: [(String, String)] = [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")]
        for (entity, char) in entities {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        // Collapse whitespace
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }
}

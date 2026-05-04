import Foundation

/// Extracts candidate vocabulary terms from pre-meeting context for STT biasing.
///
/// Targets: proper nouns, acronyms, multi-word technical terms, and names.
/// Output feeds into Azure Speech phrase lists and WhisperKit prompt conditioning.
struct VocabularyExtractor {

    /// Maximum number of phrases to send (Azure Speech has a soft limit of ~500).
    private static let maxPhrases = 200

    /// Extract vocabulary terms from freeform context text.
    static func extract(from text: String) -> [String] {
        guard !text.isEmpty else { return [] }

        var candidates = Set<String>()

        // 1. Acronyms: 2+ uppercase letters (optionally with digits)
        let acronymPattern = #"\b[A-Z][A-Z0-9]{1,9}\b"#
        if let regex = try? NSRegularExpression(pattern: acronymPattern) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                if let range = Range(match.range, in: text) {
                    let term = String(text[range])
                    // Skip common short words that happen to be uppercase
                    if !commonAcronymFalsePositives.contains(term) {
                        candidates.insert(term)
                    }
                }
            }
        }

        // 2. Capitalized multi-word phrases (proper nouns, names, titles)
        //    Pattern: 2-5 consecutive capitalized words
        let properNounPattern = #"\b([A-Z][a-z]+(?:\s+[A-Z][a-z]+){1,4})\b"#
        if let regex = try? NSRegularExpression(pattern: properNounPattern) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                if let range = Range(match.range(at: 1), in: text) {
                    let phrase = String(text[range])
                    // Skip if it's just sentence start
                    if !isLikelySentenceStart(phrase, in: text, at: range.lowerBound) {
                        candidates.insert(phrase)
                    }
                }
            }
        }

        // 3. Single capitalized words not at sentence start (names, technical terms)
        let singleCapPattern = #"(?<=[a-z.,;:!?\s])\s([A-Z][a-z]{2,})"#
        if let regex = try? NSRegularExpression(pattern: singleCapPattern) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                if let range = Range(match.range(at: 1), in: text) {
                    candidates.insert(String(text[range]))
                }
            }
        }

        // 4. Hyphenated/compound technical terms (e.g., "self-attention", "pre-training")
        let hyphenPattern = #"\b[a-zA-Z]+-[a-zA-Z]+(?:-[a-zA-Z]+)*\b"#
        if let regex = try? NSRegularExpression(pattern: hyphenPattern) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                if let range = Range(match.range, in: text) {
                    let term = String(text[range])
                    if term.count >= 5 { candidates.insert(term) }
                }
            }
        }

        // 5. Quoted terms
        let quotedPattern = #"[""]([^""]{2,40})[""]"#
        if let regex = try? NSRegularExpression(pattern: quotedPattern) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                if let range = Range(match.range(at: 1), in: text) {
                    candidates.insert(String(text[range]))
                }
            }
        }

        // Sort by length descending (longer phrases are more valuable for biasing)
        let sorted = candidates
            .filter { $0.count >= 2 }
            .sorted { $0.count > $1.count }

        return Array(sorted.prefix(maxPhrases))
    }

    /// Merge extracted terms with user-edited vocabulary list.
    static func merge(extracted: [String], userEdited: [String]) -> [String] {
        var combined = Set(userEdited) // User terms take priority
        for term in extracted {
            combined.insert(term)
        }
        return Array(combined).sorted { $0.count > $1.count }.prefix(maxPhrases).map { $0 }
    }

    // MARK: - Helpers

    private static func isLikelySentenceStart(_ phrase: String, in text: String, at position: String.Index) -> Bool {
        guard position > text.startIndex else { return true }
        let before = text[text.index(before: position)]
        return before == "." || before == "!" || before == "?" || before == "\n"
    }

    private static let commonAcronymFalsePositives: Set<String> = [
        "I", "A", "AN", "AM", "PM", "OK", "OR", "IF", "IT", "IN", "ON", "AT",
        "IS", "AS", "TO", "DO", "NO", "SO", "UP", "BY", "WE", "HE", "ME"
    ]
}

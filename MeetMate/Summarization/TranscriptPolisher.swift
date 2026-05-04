import Foundation
import Combine

/// Periodically polishes raw Whisper output into coherent paragraphs with stable IDs and timestamps.
///
/// Each cycle:
/// - Reads new segments since `cursor` from `TranscriptionService`.
/// - Sends (current draft + new raw fragments with timestamps) to the LLM.
/// - LLM returns JSON with finalized paragraphs and a draft.
/// - Swift assigns stable paragraph IDs (never the LLM) and maps timestamps from source segments.
///
/// Contract:
/// ```json
/// {
///   "finalized": [
///     {"text": "...", "sourceStart": 0, "sourceEnd": 2}
///   ],
///   "draft": "trailing in-progress thought"
/// }
/// ```
/// `sourceStart`/`sourceEnd` are indices into the numbered source segments (0-based).
/// Swift uses these to derive `startSec`/`endSec` from the original transcript timestamps.
@MainActor
final class TranscriptPolisher: ObservableObject {
    @Published private(set) var paragraphs: [PolishedParagraph] = []
    @Published private(set) var currentDraft: String = ""
    @Published private(set) var isPolishing = false

    /// Legacy accessor for backward compat — just the text of finalized paragraphs.
    var finalizedParagraphs: [String] { paragraphs.map(\.text) }

    /// Convenience: full polished view (history + draft).
    var polishedTranscript: String {
        let history = paragraphs.map { "\($0.timestampLabel) \($0.text)" }.joined(separator: "\n\n")
        if currentDraft.isEmpty { return history }
        if history.isEmpty { return currentDraft }
        return history + "\n\n" + currentDraft
    }

    private let llm: LLMService
    private let idGenerator = ParagraphIDGenerator()
    private weak var transcriber: TranscriptionService?
    private var task: Task<Void, Never>?
    private var cursor: Int = 0
    private var sessionToken: Int = 0
    private let intervalSec: TimeInterval = 25
    private let minSegmentsToPolish = 6

    /// Set by the view layer before starting. Polish output flushes to disk after each cycle.
    var sessionStorage: SessionStorage?

    /// Optional pre-meeting context injected as system prompt prefix.
    var contextProvider: (() -> String)?

    init(llm: LLMService) {
        self.llm = llm
    }

    func start(reading transcriber: TranscriptionService) {
        stop()
        sessionToken &+= 1
        self.transcriber = transcriber
        cursor = 0
        paragraphs = []
        currentDraft = ""
        idGenerator.reset()
        task = Task { [weak self] in
            guard let self else { return }
            while !self.llm.isLoaded {
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(2))
            }
            print("[Polish] LLM ready, starting polish loop")
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                await self.polishOnce()
                try? await Task.sleep(for: .seconds(self.intervalSec))
            }
        }
    }

    func stop() {
        sessionToken &+= 1
        task?.cancel()
        task = nil
        transcriber = nil
    }

    private func polishOnce() async {
        guard let transcriber else { return }
        let all = transcriber.segments
        guard all.count - cursor >= minSegmentsToPolish else { return }

        let pending = Array(all[cursor..<all.count])

        // Build numbered segment list with timestamps for the LLM
        let numberedSegments = pending.enumerated().map { idx, seg in
            let startStr = formatTime(seg.startTime)
            let endStr = formatTime(seg.endTime)
            return "[\(idx)] (\(startStr)–\(endStr)) \(seg.text)"
        }.joined(separator: "\n")

        let contextBlock: String
        if let ctx = contextProvider?(), !ctx.isEmpty {
            contextBlock = "\nMeeting context (use for domain terms, names, and accuracy):\n\(ctx)\n\n"
        } else {
            contextBlock = ""
        }

        let prompt = """
        You are an editor turning a live meeting transcript into polished paragraphs.
        \(contextBlock)Your job is to REWRITE, not just split.

        Rules:
        - Fix grammar, punctuation, and capitalization.
        - Merge short fragments into proper sentences.
        - Group related sentences into paragraphs (2–5 sentences each).
        - Light paraphrasing for clarity is allowed; preserve meaning, technical terms, and named entities exactly.
        - Keep the speaker's voice (first person if they used it).
        - DO NOT add facts the speaker didn't say.
        - DO NOT copy the input verbatim — if a paragraph reads like raw transcript, rewrite it.
        - Each finalized paragraph must specify which source segments it covers (sourceStart and sourceEnd, 0-based inclusive indices into the numbered list below).
        - Distinguish FINALIZED (speaker has moved on) from DRAFT (trailing thought still developing).
        - Prefer leaving the most recent 1–2 sentences in draft.

        Output ONLY this JSON, no markdown fences, no commentary:
        {
          "finalized": [
            {"text": "polished paragraph", "sourceStart": 0, "sourceEnd": 3}
          ],
          "draft": "trailing in-progress thought or empty string"
        }

        Previous draft (continue refining — may become finalized):
        \(currentDraft.isEmpty ? "(none)" : currentDraft)

        New source segments (numbered with timestamps):
        \(numberedSegments)
        /no_think
        """

        isPolishing = true
        defer { isPolishing = false }
        let token = sessionToken
        do {
            let response = try await llm.generate(prompt: prompt, maxTokens: 1500)
            guard token == sessionToken, !Task.isCancelled else {
                print("[Polish] dropping stale result from prior session")
                return
            }
            guard let parsed = parseResponse(response) else {
                print("[Polish] parse failed, raw response: \(response.prefix(200)) — keeping cursor for retry next cycle")
                return
            }

            // Assign stable IDs and map timestamps from source segments
            var newParagraphs: [PolishedParagraph] = []
            for item in parsed.finalized {
                let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                let startIdx = max(0, min(item.sourceStart, pending.count - 1))
                let endIdx = max(startIdx, min(item.sourceEnd, pending.count - 1))
                let startSec = Float(pending[startIdx].startTime)
                let endSec = Float(pending[endIdx].endTime)

                let para = PolishedParagraph(
                    id: idGenerator.next(),
                    text: text,
                    startSec: startSec,
                    endSec: endSec,
                    version: 1
                )
                newParagraphs.append(para)
            }

            if !newParagraphs.isEmpty {
                paragraphs.append(contentsOf: newParagraphs)
                print("[Polish] +\(newParagraphs.count) paragraph(s), draft: \(parsed.draft.prefix(60))…")

                // Persist each new paragraph
                for para in newParagraphs {
                    sessionStorage?.appendParagraph(para)
                }
            } else if !parsed.draft.isEmpty {
                print("[Polish] draft updated: \(parsed.draft.prefix(80))…")
            }
            currentDraft = parsed.draft
            cursor = all.count

            sessionStorage?.writePolished(paragraphs: finalizedParagraphs, draft: currentDraft)
        } catch {
            print("[Polish] failed: \(error)")
        }
    }

    private struct FinalizedItem {
        let text: String
        let sourceStart: Int
        let sourceEnd: Int
    }

    private struct PolishResponse {
        let finalized: [FinalizedItem]
        let draft: String
    }

    private func parseResponse(_ text: String) -> PolishResponse? {
        guard let json = extractJSON(from: text),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let draft = (obj["draft"] as? String) ?? ""
        var items: [FinalizedItem] = []

        if let finalized = obj["finalized"] as? [[String: Any]] {
            for entry in finalized {
                let text = (entry["text"] as? String) ?? ""
                let sourceStart = (entry["sourceStart"] as? Int) ?? 0
                let sourceEnd = (entry["sourceEnd"] as? Int) ?? sourceStart
                items.append(FinalizedItem(text: text, sourceStart: sourceStart, sourceEnd: sourceEnd))
            }
        } else if let finalized = obj["finalized"] as? [String] {
            // Fallback: LLM returned plain strings (no source indices) — assign full range
            for text in finalized {
                items.append(FinalizedItem(text: text, sourceStart: 0, sourceEnd: 0))
            }
        }

        return PolishResponse(finalized: items, draft: draft)
    }

    private func extractJSON(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"), start < end else { return nil }
        return String(text[start...end])
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let min = total / 60
        let sec = total % 60
        return String(format: "%02d:%02d", min, sec)
    }
}

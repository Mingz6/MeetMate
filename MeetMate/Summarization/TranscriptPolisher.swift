import Foundation
import Combine

/// Periodically polishes raw Whisper output into coherent paragraphs.
///
/// Each cycle:
/// - Reads new segments since `cursor` from `TranscriptionService`.
/// - Sends (current draft + new raw fragments) to the LLM.
/// - LLM returns JSON: `{ "finalized": [...], "draft": "..." }`.
///   - `finalized` = complete coherent thoughts/paragraphs (immutable, appended to history).
///   - `draft` = trailing in-progress thought (replaced each cycle).
///
/// Why: gives you scroll-back text you can quote — "you said X, explain why" — instead of fragmented chunks.
@MainActor
final class TranscriptPolisher: ObservableObject {
    @Published private(set) var finalizedParagraphs: [String] = []
    @Published private(set) var currentDraft: String = ""
    @Published private(set) var isPolishing = false

    /// Convenience: full polished view (history + draft).
    var polishedTranscript: String {
        let history = finalizedParagraphs.joined(separator: "\n\n")
        if currentDraft.isEmpty { return history }
        if history.isEmpty { return currentDraft }
        return history + "\n\n" + currentDraft
    }

    private let llm: LLMService
    private weak var transcriber: TranscriptionService?
    private var task: Task<Void, Never>?
    private var cursor: Int = 0
    private let intervalSec: TimeInterval = 25
    private let minSegmentsToPolish = 6

    init(llm: LLMService) {
        self.llm = llm
    }

    func start(reading transcriber: TranscriptionService) {
        stop()
        self.transcriber = transcriber
        cursor = 0
        finalizedParagraphs = []
        currentDraft = ""
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
        task?.cancel()
        task = nil
        transcriber = nil
    }

    private func polishOnce() async {
        guard let transcriber else { return }
        let all = transcriber.segments
        guard all.count - cursor >= minSegmentsToPolish else { return }

        let pending = Array(all[cursor..<all.count])
        let raw = pending.map(\.text).joined(separator: " ")

        let prompt = """
        You are an editor turning a clean live meeting transcript into the kind of polished paragraphs that would appear in published notes or a transcript article.

        Your job is to REWRITE, not just split.

        Rules:
        - Fix grammar, punctuation, and capitalization.
        - Merge short fragments into proper sentences.
        - Group related sentences into paragraphs (2–5 sentences each).
        - Light paraphrasing for clarity is allowed; preserve the speaker's meaning, technical terms, and named entities exactly.
        - Keep the speaker's voice (first person if they used it).
        - DO NOT add facts the speaker didn't say.
        - DO NOT copy the input verbatim — if a paragraph reads like raw transcript, rewrite it.
        - Distinguish FINALIZED (the speaker has clearly moved on from this topic — safe to lock in) from DRAFT (the trailing thought they're still developing).
        - The draft will be re-edited next cycle, so prefer leaving the most recent 1–2 sentences in draft.

        Output ONLY this JSON, no markdown fences, no commentary:
        {
          "finalized": ["polished paragraph 1", "polished paragraph 2"],
          "draft": "trailing in-progress thought as a single string, or empty string"
        }

        Previous draft (continue refining this — it may end up in finalized this cycle):
        \(currentDraft.isEmpty ? "(none)" : currentDraft)

        New raw transcript to incorporate:
        \(raw)
        /no_think
        """

        isPolishing = true
        defer { isPolishing = false }
        do {
            let response = try await llm.generate(prompt: prompt, maxTokens: 1200)
            guard let parsed = parseResponse(response) else {
                print("[Polish] parse failed, raw response: \(response.prefix(200))")
                cursor = all.count
                return
            }

            let newFinals = parsed.finalized.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !newFinals.isEmpty {
                finalizedParagraphs.append(contentsOf: newFinals)
                print("[Polish] +\(newFinals.count) paragraph(s), draft: \(parsed.draft.prefix(60))…")
            } else if !parsed.draft.isEmpty {
                print("[Polish] draft updated: \(parsed.draft.prefix(80))…")
            }
            currentDraft = parsed.draft
            cursor = all.count
        } catch {
            print("[Polish] failed: \(error)")
        }
    }

    private struct PolishResponse {
        let finalized: [String]
        let draft: String
    }

    private func parseResponse(_ text: String) -> PolishResponse? {
        guard let json = extractJSON(from: text),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let finalized = (obj["finalized"] as? [String]) ?? []
        let draft = (obj["draft"] as? String) ?? ""
        return PolishResponse(finalized: finalized, draft: draft)
    }

    private func extractJSON(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"), start < end else { return nil }
        return String(text[start...end])
    }
}

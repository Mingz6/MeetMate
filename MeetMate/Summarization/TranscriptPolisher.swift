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
    @Published private(set) var pendingRevisions: [ParagraphRevision] = []

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
    private var polishCycleCount: Int = 0
    private let rePolishEveryN = 3
    private let rePolishWindowSize = 5
    private let rePolishMinAgeSec: TimeInterval = 10

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
                self.polishCycleCount += 1
                // Re-polish every N cycles (cloud-only)
                if self.polishCycleCount % self.rePolishEveryN == 0 {
                    await self.rePolishOnce()
                }
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

        // Build numbered segment list with timestamps and source tags for the LLM
        let numberedSegments = pending.enumerated().map { idx, seg in
            let startStr = formatTime(seg.startTime)
            let endStr = formatTime(seg.endTime)
            let sourceTag: String
            switch seg.source {
            case "mic": sourceTag = " [me]"
            case "system": sourceTag = " [remote]"
            default: sourceTag = ""
            }
            return "[\(idx)] (\(startStr)–\(endStr))\(sourceTag) \(seg.text)"
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
        - Segments tagged [me] are from the local microphone (the user). Segments tagged [remote] are from system audio (remote meeting participants). Prefer grouping same-source segments into the same paragraph when they're contiguous.
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

                // Derive dominant audio source from covered segments
                let coveredSegments = pending[startIdx...endIdx]
                let source = dominantSource(of: coveredSegments)

                let para = PolishedParagraph(
                    id: idGenerator.next(),
                    text: text,
                    startSec: startSec,
                    endSec: endSec,
                    version: 1,
                    source: source
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

    // MARK: - Re-polish (§6)

    private func rePolishOnce() async {
        // Cloud-only — local models aren't good enough for revision judgment
        guard llm.activeProvider == .cloud else { return }
        guard paragraphs.count >= 3 else { return }

        // Window: last N paragraphs, excluding those newer than ~10s (still being polished live)
        let cutoffEndSec: Float
        if let transcriber, let lastSeg = transcriber.segments.last {
            cutoffEndSec = Float(lastSeg.endTime) - Float(rePolishMinAgeSec)
        } else {
            cutoffEndSec = .greatestFiniteMagnitude
        }

        let eligible = paragraphs.filter { $0.endSec < cutoffEndSec }
        guard eligible.count >= 2 else { return }

        let window = Array(eligible.suffix(rePolishWindowSize))
        let windowText = window.map { "[\($0.id)] \($0.timestampLabel) \($0.text)" }.joined(separator: "\n")
        let windowIds = window.map(\.id)

        let contextBlock: String
        if let ctx = contextProvider?(), !ctx.isEmpty {
            contextBlock = "\nMeeting context:\n\(ctx)\n\n"
        } else {
            contextBlock = ""
        }

        let prompt = """
        You are a senior editor reviewing polished meeting notes. Below are recent paragraphs (each tagged with their stable ID).
        \(contextBlock)
        Your task: look for improvements. Common reasons to revise:
        - Speaker corrected themselves later ("Actually, I meant X not Y")
        - Two paragraphs can be merged for better flow
        - A paragraph is awkward or could be clearer with minor rewording
        - Factual inconsistency between adjacent paragraphs

        If NO revision is needed, return: {"revisions": []}

        If revision IS needed, return:
        {
          "revisions": [
            {
              "replaceIds": ["p_000003", "p_000004"],
              "newText": "The merged/revised paragraph text here.",
              "reason": "Brief explanation of why this revision improves the text"
            }
          ]
        }

        Rules:
        - Only reference IDs from the list below — never invent IDs.
        - Maximum 2 revisions per cycle (don't over-edit).
        - Preserve timestamps/meaning — you're polishing, not rewriting from scratch.
        - If the text already reads well, return empty revisions array.

        Current paragraphs:
        \(windowText)
        /no_think
        """

        let token = sessionToken
        do {
            let response = try await llm.generate(prompt: prompt, maxTokens: 800)
            guard token == sessionToken, !Task.isCancelled else { return }
            guard let revisions = parseRevisionResponse(response, validIds: Set(windowIds)) else {
                print("[RePolish] parse failed: \(response.prefix(200))")
                return
            }
            if revisions.isEmpty {
                print("[RePolish] no revisions suggested")
                return
            }
            pendingRevisions.append(contentsOf: revisions)
            print("[RePolish] +\(revisions.count) revision(s) pending")
        } catch {
            print("[RePolish] failed: \(error)")
        }
    }

    // MARK: - Accept / Reject revisions

    func acceptRevision(_ revision: ParagraphRevision) {
        pendingRevisions.removeAll { $0.id == revision.id }

        // Find the paragraphs being replaced, merge their time range
        let targets = paragraphs.filter { revision.replaceIds.contains($0.id) }
        guard !targets.isEmpty else { return }

        let firstId = targets.first!.id
        let startSec = targets.map(\.startSec).min() ?? 0
        let endSec = targets.map(\.endSec).max() ?? 0
        let maxVersion = targets.map(\.version).max() ?? 0

        // Build the revised paragraph (same ID as the first target, bumped version)
        let revised = PolishedParagraph(
            id: firstId,
            text: revision.newText,
            startSec: startSec,
            endSec: endSec,
            version: maxVersion + 1,
            source: targets.first?.source
        )

        // Replace in the paragraphs array: remove all targets, insert revised at first target's position
        if let insertIdx = paragraphs.firstIndex(where: { $0.id == firstId }) {
            paragraphs.removeAll { revision.replaceIds.contains($0.id) }
            let safeIdx = min(insertIdx, paragraphs.count)
            paragraphs.insert(revised, at: safeIdx)
        }

        // Persist the revised version (append-only — old versions stay in the file)
        sessionStorage?.appendParagraph(revised)
        sessionStorage?.writePolished(paragraphs: finalizedParagraphs, draft: currentDraft)
        print("[RePolish] accepted revision for \(revision.replaceIds.joined(separator: ", "))")
    }

    func rejectRevision(_ revision: ParagraphRevision) {
        pendingRevisions.removeAll { $0.id == revision.id }
        print("[RePolish] rejected revision for \(revision.replaceIds.joined(separator: ", "))")
    }

    private func parseRevisionResponse(_ text: String, validIds: Set<String>) -> [ParagraphRevision]? {
        guard let json = extractJSON(from: text),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let revisions = obj["revisions"] as? [[String: Any]] else {
            return nil
        }

        var results: [ParagraphRevision] = []
        for entry in revisions {
            guard let replaceIds = entry["replaceIds"] as? [String],
                  let newText = entry["newText"] as? String,
                  !replaceIds.isEmpty, !newText.isEmpty else { continue }
            // Only accept revisions referencing valid paragraph IDs
            guard replaceIds.allSatisfy({ validIds.contains($0) }) else { continue }
            let reason = (entry["reason"] as? String) ?? ""
            results.append(ParagraphRevision(replaceIds: replaceIds, newText: newText, reason: reason))
        }
        return results
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

    /// Determine the dominant audio source from a slice of transcript segments.
    /// Returns nil if all segments are nil/mixed.
    private func dominantSource(of segments: ArraySlice<TranscriptSegment>) -> AudioSource? {
        var micCount = 0
        var sysCount = 0
        for seg in segments {
            switch seg.source {
            case "mic": micCount += 1
            case "system": sysCount += 1
            default: break
            }
        }
        if micCount == 0 && sysCount == 0 { return nil }
        return micCount >= sysCount ? .mic : .system
    }
}

import Foundation
import Combine

@MainActor
final class CheatsheetGenerator: ObservableObject {
    @Published var current = Cheatsheet()

    private let llm: LLMService
    private var rollingTask: Task<Void, Never>?
    private var sessionToken: Int = 0
    private let updateIntervalSec: TimeInterval = 30

    /// Set by the view layer before starting. Cheatsheet flushes to disk after each refresh.
    var sessionStorage: SessionStorage?

    /// Optional pre-meeting context injected as system prompt prefix.
    var contextProvider: (() -> String)?

    init(llm: LLMService) {
        self.llm = llm
    }

    func startRolling(transcriptProvider: @escaping () -> String) {
        rollingTask?.cancel()
        sessionToken &+= 1
        rollingTask = Task { [weak self] in
            guard let self else { return }
            // Wait until LLM is loaded before polling
            while !self.llm.isLoaded {
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(2))
            }
            print("[Cheatsheet] LLM ready, starting rolling updates")
            try? await Task.sleep(for: .seconds(15))
            while !Task.isCancelled {
                let transcript = transcriptProvider()
                if transcript.count > 50 {
                    await self.refresh(transcript: transcript)
                }
                try? await Task.sleep(for: .seconds(self.updateIntervalSec))
            }
        }
    }

    func stopRolling() {
        sessionToken &+= 1
        rollingTask?.cancel()
        rollingTask = nil
    }

    func refresh(transcript: String) async {
        let contextBlock: String
        if let ctx = contextProvider?(), !ctx.isEmpty {
            contextBlock = "\nMeeting context (use to inform topic detection and terminology):\n\(ctx)\n\n"
        } else {
            contextBlock = ""
        }

        let prompt = """
        You are a meeting assistant. Read the transcript and output ONLY a JSON object with these exact keys:
        {
          "currentTopic": "one short sentence",
          "keyPoints": ["3 to 5 short bullets"],
          "openQuestions": ["any unresolved questions, can be empty"],
          "actionItems": ["any TODOs/owners mentioned, can be empty"]
        }
        Output JSON only — no markdown fences, no commentary.
        \(contextBlock)Transcript (most recent):
        \(transcript.suffix(4000))
        /no_think
        """

        let token = sessionToken
        do {
            print("[Cheatsheet] refreshing…")
            let response = try await llm.generate(prompt: prompt, maxTokens: 600)
            guard token == sessionToken, !Task.isCancelled else {
                print("[Cheatsheet] dropping stale result from prior session")
                return
            }
            print("[Cheatsheet] raw response:\n\(response)")
            current = parseCheatsheet(from: response, previous: current)
            print("[Cheatsheet] topic=\(current.currentTopic) points=\(current.keyPoints.count) Qs=\(current.openQuestions.count) actions=\(current.actionItems.count)")

            sessionStorage?.writeCheatsheet(
                topic: current.currentTopic,
                keyPoints: current.keyPoints,
                questions: current.openQuestions,
                actions: current.actionItems
            )
        } catch {
            print("[Cheatsheet] refresh failed: \(error)")
        }
    }

    private func parseCheatsheet(from response: String, previous: Cheatsheet) -> Cheatsheet {
        var sheet = previous
        sheet.lastUpdated = .now

        guard let json = extractJSON(from: response),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Fallback: keep prior sheet's fields, just stamp time. One bad parse shouldn't
            // wipe valid key points / questions / actions.
            print("[Cheatsheet] JSON parse failed, keeping previous fields")
            return sheet
        }

        if let topic = obj["currentTopic"] as? String { sheet.currentTopic = topic }
        if let pts = obj["keyPoints"] as? [String] { sheet.keyPoints = pts }
        if let qs = obj["openQuestions"] as? [String] { sheet.openQuestions = qs }
        if let acts = obj["actionItems"] as? [String] { sheet.actionItems = acts }
        return sheet
    }

    /// Pull the first {...} block out of a model response (strips markdown fences and chatter).
    private func extractJSON(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"), start < end else { return nil }
        return String(text[start...end])
    }
}

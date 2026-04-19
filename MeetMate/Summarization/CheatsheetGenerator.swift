import Foundation
import Combine

@MainActor
final class CheatsheetGenerator: ObservableObject {
    @Published var current = Cheatsheet()

    private let llm: LLMService
    private var rollingTask: Task<Void, Never>?
    private let updateIntervalSec: TimeInterval = 30

    init(llm: LLMService) {
        self.llm = llm
    }

    func startRolling(transcriptProvider: @escaping () -> String) {
        rollingTask?.cancel()
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
        rollingTask?.cancel()
        rollingTask = nil
    }

    func refresh(transcript: String) async {
        let prompt = """
        You are a meeting assistant. Read the transcript and output ONLY a JSON object with these exact keys:
        {
          "currentTopic": "one short sentence",
          "keyPoints": ["3 to 5 short bullets"],
          "openQuestions": ["any unresolved questions, can be empty"],
          "actionItems": ["any TODOs/owners mentioned, can be empty"]
        }
        Output JSON only — no markdown fences, no commentary.

        Transcript (most recent):
        \(transcript.suffix(4000))
        /no_think
        """

        do {
            print("[Cheatsheet] refreshing…")
            let response = try await llm.generate(prompt: prompt, maxTokens: 600)
            print("[Cheatsheet] raw response:\n\(response)")
            current = parseCheatsheet(from: response)
            print("[Cheatsheet] topic=\(current.currentTopic) points=\(current.keyPoints.count) Qs=\(current.openQuestions.count) actions=\(current.actionItems.count)")
        } catch {
            print("[Cheatsheet] refresh failed: \(error)")
        }
    }

    private func parseCheatsheet(from response: String) -> Cheatsheet {
        var sheet = Cheatsheet()
        sheet.lastUpdated = .now

        guard let json = extractJSON(from: response),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Fallback: keep prior sheet's fields, just stamp time
            print("[Cheatsheet] JSON parse failed, falling back to plain text")
            sheet.currentTopic = String(response.prefix(200))
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

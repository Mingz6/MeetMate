import Foundation
import Combine

@MainActor
final class ReplyGenerator: ObservableObject {
    @Published var pendingSuggestion: ReplySuggestion?

    private let llm: LLMService
    private var watchTask: Task<Void, Never>?
    private var sessionToken: Int = 0
    private var lastDetectionAt: Date = .distantPast
    private var lastMentionSentence: String = ""
    private let cooldownSec: TimeInterval = 15

    init(llm: LLMService) {
        self.llm = llm
    }

    func startWatching(
        userName: String,
        transcriptProvider: @escaping () -> String,
        cheatsheetProvider: @escaping () -> Cheatsheet
    ) {
        watchTask?.cancel()
        sessionToken &+= 1
        lastMentionSentence = ""
        watchTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))

                let transcript = transcriptProvider()
                let recent = String(transcript.suffix(800))

                if let question = self.detectMention(of: userName, in: recent),
                   question != self.lastMentionSentence,
                   Date().timeIntervalSince(self.lastDetectionAt) > self.cooldownSec {
                    self.lastDetectionAt = .now
                    self.lastMentionSentence = question
                    await self.generateReply(question: question, transcript: recent, sheet: cheatsheetProvider())
                }
            }
        }
    }

    func stopWatching() {
        sessionToken &+= 1
        watchTask?.cancel()
        watchTask = nil
    }

    private func detectMention(of name: String, in text: String) -> String? {
        let patterns = [
            "\(name),",
            "\(name)?",
            "\(name) what",
            "what do you think \(name)",
            "\(name) thoughts",
            "over to you \(name)"
        ]
        let lower = text.lowercased()
        let nameLower = name.lowercased()
        guard patterns.contains(where: { lower.contains($0.lowercased()) }) || lower.contains(nameLower) else {
            return nil
        }
        // Pull the surrounding sentence as the "question"
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
        return sentences.last(where: { $0.lowercased().contains(nameLower) })?
            .trimmingCharacters(in: .whitespaces)
    }

    func triggerManually(transcript: String, cheatsheet: Cheatsheet) async {
        let recent = String(transcript.suffix(800))
        await generateReply(question: "(manual trigger — craft a reply for me)", transcript: recent, sheet: cheatsheet)
    }

    private func generateReply(question: String, transcript: String, sheet: Cheatsheet) async {
        let prompt = """
        Someone in the meeting just addressed you. Suggest a 2-3 sentence professional reply.

        Question/prompt directed at you: "\(question)"

        Current meeting topic: \(sheet.currentTopic)
        Key points so far: \(sheet.keyPoints.joined(separator: "; "))

        Recent conversation:
        \(transcript)

        Reply (2-3 sentences, friendly and direct, no preamble):
        /no_think
        """

        let token = sessionToken
        do {
            let reply = try await llm.generate(prompt: prompt, maxTokens: 200)
            guard token == sessionToken, !Task.isCancelled else {
                print("[Reply] dropping stale suggestion from prior session")
                return
            }
            pendingSuggestion = ReplySuggestion(triggerQuestion: question, suggestedReply: reply)
        } catch {
            print("Reply generation failed: \(error)")
        }
    }

    func dismiss() {
        pendingSuggestion = nil
    }
}

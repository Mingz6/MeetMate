import Foundation
import Combine

/// Periodically analyzes the latest captured screen frame using GPT-4o vision.
/// Feeds the description into the cheatsheet's `screenContext` field.
@MainActor
final class VisionService: ObservableObject {
    @Published private(set) var lastAnalysis: String = ""
    @Published private(set) var isAnalyzing = false

    private let llm: LLMService
    private var rollingTask: Task<Void, Never>?
    private var sessionToken: Int = 0

    /// How often to run vision analysis (seconds). Longer = cheaper.
    var analysisInterval: TimeInterval = 30

    /// Provides the latest frame JPEG data.
    var frameProvider: (() -> (data: Data, timestamp: TimeInterval)?)?

    /// Provides recent transcript context for the vision prompt.
    var transcriptProvider: (() -> String)?

    /// Callback to update cheatsheet with screen context.
    var onScreenContext: ((String) -> Void)?

    init(llm: LLMService) {
        self.llm = llm
    }

    func startRolling() {
        rollingTask?.cancel()
        sessionToken &+= 1
        let token = sessionToken

        rollingTask = Task { [weak self] in
            // Initial delay — give the meeting time to produce frames
            try? await Task.sleep(for: .seconds(10))

            while !Task.isCancelled {
                guard let self, token == self.sessionToken else { return }
                await self.analyzeLatestFrame()
                try? await Task.sleep(for: .seconds(self.analysisInterval))
            }
        }
    }

    func stopRolling() {
        sessionToken &+= 1
        rollingTask?.cancel()
        rollingTask = nil
    }

    func analyzeLatestFrame() async {
        guard let frameProvider, let frame = frameProvider() else { return }
        guard !isAnalyzing else { return }

        isAnalyzing = true
        defer { isAnalyzing = false }

        let transcriptSnippet = transcriptProvider?().suffix(1500) ?? ""
        let prompt = """
        You are a meeting assistant with screen vision. Describe what's currently visible on screen in 2-3 concise sentences. Focus on: slide content, code shown, documents, diagrams, or shared applications. If it's just a video call grid with no shared content, say "Video call — no shared content."

        Recent transcript context for reference:
        \(transcriptSnippet)
        """

        guard let result = await llm.generateWithVision(prompt: prompt, imageJPEG: frame.data, maxTokens: 200) else {
            return
        }

        lastAnalysis = result
        onScreenContext?(result)
        print("[Vision] screen analysis: \(result.prefix(100))…")
    }
}

import Foundation
import Combine
#if os(iOS)
import UIKit
#endif
import MLX
import MLXLLM
import MLXLMCommon

@MainActor
final class LLMService: ObservableObject {
    enum ModelChoice: String, CaseIterable, Identifiable {
        case llama3_8b = "mlx-community/Llama-3.1-8B-Instruct-4bit"
        case qwen3_14b = "mlx-community/Qwen3-14B-4bit"
        case qwen3_4b = "mlx-community/Qwen3-4B-4bit"
        case phi3Mini = "mlx-community/Phi-3-mini-4k-instruct-4bit"
        case qwen2_5_1_5b = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"

        var id: String { rawValue }

        var approximateSizeGB: Double {
            switch self {
            case .qwen3_14b: return 8.0
            case .llama3_8b: return 4.5
            case .qwen3_4b: return 2.5
            case .phi3Mini: return 2.3
            case .qwen2_5_1_5b: return 1.0
            }
        }

        var displayName: String {
            switch self {
            case .llama3_8b: return "Llama 3.1 8B (Q4)"
            case .qwen3_14b: return "Qwen3 14B (Q4)"
            case .qwen3_4b: return "Qwen3 4B (Q4)"
            case .phi3Mini: return "Phi-3 mini (Q4)"
            case .qwen2_5_1_5b: return "Qwen2.5 1.5B (Q4)"
            }
        }
    }

    @Published private(set) var isLoaded = false
    @Published private(set) var isGenerating = false
    @Published private(set) var loadedModel: ModelChoice?

    private var modelContainer: ModelContainer?

    static func recommendedModel() -> ModelChoice {
        let totalRAMGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824

        #if os(macOS)
        if totalRAMGB >= 32 { return .qwen3_14b }
        if totalRAMGB >= 16 { return .llama3_8b }
        return .qwen3_4b
        #elseif os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            return totalRAMGB >= 12 ? .qwen3_4b : .phi3Mini
        }
        return totalRAMGB >= 8 ? .phi3Mini : .qwen2_5_1_5b
        #else
        return .qwen3_4b
        #endif
    }

    func load(_ choice: ModelChoice? = nil) async throws {
        let target = choice ?? Self.recommendedModel()
        print("[LLM] loading \(target.displayName) (\(target.approximateSizeGB)GB on first run)…")
        // Cap GPU cache so the LLM doesn't fight Whisper for memory
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)

        let config = ModelConfiguration(id: target.rawValue)
        var lastReportedPct = -1
        let container = try await LLMModelFactory.shared.loadContainer(configuration: config) { progress in
            let pct = Int(progress.fractionCompleted * 100)
            if pct >= lastReportedPct + 5 {
                lastReportedPct = pct
                print("[LLM] download \(pct)%")
            }
        }
        modelContainer = container
        loadedModel = target
        isLoaded = true
        print("[LLM] model ready")
    }

    func generate(prompt: String, maxTokens: Int = 512) async throws -> String {
        guard let container = modelContainer else { throw LLMError.notLoaded }
        isGenerating = true
        defer { isGenerating = false }

        let session = ChatSession(
            container,
            generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0.3)
        )
        let raw = try await session.respond(to: prompt)
        return Self.stripThinking(raw)
    }

    /// Qwen3 emits <think>...</think> blocks. Strip them before returning to callers.
    private static func stripThinking(_ text: String) -> String {
        var out = text
        // Greedy strip of any <think>...</think> blocks (single or multiline)
        if let regex = try? NSRegularExpression(pattern: "<think>[\\s\\S]*?</think>", options: []) {
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: "")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum LLMError: Error {
    case notLoaded
    case generationFailed(String)
}

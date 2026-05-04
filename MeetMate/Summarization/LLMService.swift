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

    // MARK: - Provider mode

    enum ProviderMode: String {
        case cloud = "Cloud (Azure OpenAI)"
        case local = "Local (MLX)"
        case recordingOnly = "Recording Only"
    }

    // MARK: - Local model choices

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

    // MARK: - Published state

    @Published private(set) var isLoaded = false
    @Published private(set) var isGenerating = false
    @Published private(set) var loadedModel: ModelChoice?
    @Published private(set) var loadProgress: Double = 0
    @Published private(set) var activeProvider: ProviderMode = .recordingOnly
    @Published private(set) var sessionUsage = SessionTokenUsage()
    @Published var cloudPaused = false {
        didSet {
            if cloudPaused {
                reachability.pauseCloud()
            } else {
                reachability.resumeCloud()
            }
            resolveActiveProvider()
        }
    }

    // MARK: - Dependencies

    let reachability: ReachabilityMonitor
    private let azure = AzureOpenAIProvider()
    private let replayQueue = ReplayQueue()
    private var modelContainer: ModelContainer?
    private var reachabilityCancellable: AnyCancellable?

    // MARK: - Init

    init(reachability: ReachabilityMonitor? = nil) {
        self.reachability = reachability ?? ReachabilityMonitor()
        // Watch for reachability changes to switch providers
        reachabilityCancellable = self.reachability.$isCloudAvailable
            .receive(on: RunLoop.main)
            .sink { [weak self] available in
                self?.resolveActiveProvider()
                if available { Task { [weak self] in _ = await self?.drainReplayQueue() } }
            }
        resolveActiveProvider()
    }

    // MARK: - Load local model (fallback)

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

    func loadLocalModel(_ choice: ModelChoice? = nil) async throws {
        let target = choice ?? Self.recommendedModel()
        print("[LLM] loading local \(target.displayName) (\(target.approximateSizeGB)GB on first run)…")
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
        loadProgress = 0

        let config = ModelConfiguration(id: target.rawValue)
        let progressBox = ProgressBox()
        let progressUpdate: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor [weak self] in self?.loadProgress = fraction }
        }
        let container = try await LLMModelFactory.shared.loadContainer(configuration: config) { progress in
            let fraction = progress.fractionCompleted
            let pct = Int(fraction * 100)
            progressUpdate(fraction)
            if progressBox.shouldLog(pct: pct) {
                print("[LLM] download \(pct)%")
            }
        }
        modelContainer = container
        loadedModel = target
        loadProgress = 1
        isLoaded = true
        resolveActiveProvider()
        print("[LLM] local model ready")
    }

    /// Legacy compatibility — same as `loadLocalModel`.
    func load(_ choice: ModelChoice? = nil) async throws {
        try await loadLocalModel(choice)
    }

    // MARK: - Generate (provider-routed)

    /// Generate text using the best available provider (cloud → local → recording-only).
    /// Consumer API is unchanged from pre-§2.
    func generate(prompt: String, maxTokens: Int = 512) async throws -> String {
        try await generate(prompt: prompt, maxTokens: maxTokens, task: .general)
    }

    /// Generate with explicit task type for per-deployment routing.
    func generate(prompt: String, maxTokens: Int = 512, task: LLMTask) async throws -> String {
        isGenerating = true
        defer { isGenerating = false }

        // Try cloud first
        if activeProvider == .cloud {
            do {
                let result = try await azure.generate(prompt: prompt, maxTokens: maxTokens, task: task)
                reachability.reportSuccess()
                if let usage = result.usage {
                    sessionUsage.add(usage)
                }
                return result.text
            } catch {
                reachability.reportFailure()
                resolveActiveProvider()
                print("[LLM] cloud failed: \(error.localizedDescription), falling back")
            }
        }

        // Try local fallback
        if let container = modelContainer {
            let session = ChatSession(
                container,
                generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0.3)
            )
            let raw = try await session.respond(to: prompt)
            return Self.stripThinking(raw)
        }

        // Both unavailable — we're in recording-only mode. Throw so callers know.
        throw LLMError.noProviderAvailable
    }

    /// Generate with explicit task type — used for replay queue support.
    func generate(prompt: String, maxTokens: Int = 512, taskType: ReplayJob.TaskType) async throws -> String {
        do {
            return try await generate(prompt: prompt, maxTokens: maxTokens)
        } catch LLMError.noProviderAvailable {
            // Queue for later replay
            let job = ReplayJob(taskType: taskType, prompt: prompt, maxTokens: maxTokens, timestamp: Date())
            await replayQueue.enqueue(job)
            print("[LLM] queued \(taskType.rawValue) job for replay (\(await replayQueue.count) pending)")
            throw LLMError.noProviderAvailable
        }
    }

    // MARK: - Vision (cloud-only)

    /// Generate with a screen frame + text prompt. Cloud-only (GPT-4o vision).
    /// Returns nil if cloud is unavailable (vision has no local fallback).
    func generateWithVision(prompt: String, imageJPEG: Data, maxTokens: Int = 300) async -> String? {
        guard activeProvider == .cloud else { return nil }
        isGenerating = true
        defer { isGenerating = false }

        do {
            let result = try await azure.generateWithVision(prompt: prompt, imageJPEG: imageJPEG, maxTokens: maxTokens)
            reachability.reportSuccess()
            if let usage = result.usage {
                sessionUsage.add(usage)
            }
            return result.text
        } catch {
            print("[LLM] vision call failed: \(error.localizedDescription)")
            reachability.reportFailure()
            resolveActiveProvider()
            return nil
        }
    }

    // MARK: - Replay queue drain

    /// Attempt to drain replay queue. Call when cloud comes back.
    func drainReplayQueue() async -> [String] {
        guard activeProvider == .cloud else { return [] }
        let pending = await replayQueue.pending()
        guard !pending.isEmpty else { return [] }
        print("[LLM] draining \(pending.count) replay jobs")

        var results: [String] = []
        for job in pending {
            do {
                let text = try await generate(prompt: job.prompt, maxTokens: job.maxTokens)
                results.append(text)
                await replayQueue.remove(job)
            } catch {
                // If cloud fails again during drain, stop
                print("[LLM] replay drain failed at job \(job.taskType.rawValue): \(error)")
                break
            }
        }
        return results
    }

    // MARK: - Cost tracking

    var pendingReplayCount: Int {
        get async { await replayQueue.count }
    }

    // MARK: - Provider resolution

    private func resolveActiveProvider() {
        if azure.isConfigured && reachability.isCloudAvailable && !cloudPaused {
            activeProvider = .cloud
        } else if modelContainer != nil {
            activeProvider = .local
        } else {
            activeProvider = .recordingOnly
        }
    }

    // MARK: - Private helpers

    private static func stripThinking(_ text: String) -> String {
        var out = text
        if let regex = try? NSRegularExpression(pattern: "<think>[\\s\\S]*?</think>", options: []) {
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: "")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Session token tracking

struct SessionTokenUsage {
    private(set) var promptTokens = 0
    private(set) var completionTokens = 0
    var totalTokens: Int { promptTokens + completionTokens }

    /// Rough estimate at $0.01/1K prompt + $0.03/1K completion (GPT-4o pricing ballpark).
    var estimatedCostUSD: Double {
        (Double(promptTokens) / 1000 * 0.01) + (Double(completionTokens) / 1000 * 0.03)
    }

    mutating func add(_ usage: TokenUsage) {
        promptTokens += usage.promptTokens
        completionTokens += usage.completionTokens
    }

    mutating func reset() {
        promptTokens = 0
        completionTokens = 0
    }
}

// MARK: - Errors

enum LLMError: Error {
    case notLoaded
    case noProviderAvailable
    case generationFailed(String)
}

// MARK: - Progress logging helper

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var lastReportedPct = -1

    nonisolated func shouldLog(pct: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pct >= lastReportedPct + 5 else { return false }
        lastReportedPct = pct
        return true
    }
}

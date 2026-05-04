import Foundation

/// Token usage from a single LLM call.
struct TokenUsage: Sendable {
    let promptTokens: Int
    let completionTokens: Int
    var totalTokens: Int { promptTokens + completionTokens }
}

/// Result of a single LLM generation call.
struct LLMResult: Sendable {
    let text: String
    let usage: TokenUsage?
}

/// Task types for per-task model routing.
/// Polish/cheatsheet use a cheaper mini deployment; re-polish/vision use the full model.
enum LLMTask: String, Sendable {
    case polish          // Rolling polish (high frequency, cheaper model OK)
    case cheatsheet      // Rolling topic summary (high frequency)
    case reply           // Reply suggestion (infrequent, needs quality)
    case rePolish        // Retroactive re-polish (infrequent, needs quality)
    case batchPolish     // One-shot batch re-polish after accept
    case vision          // Screen frame analysis (needs multimodal)
    case general         // Default / other

    /// Whether this task should route to the mini (cheaper) deployment when available.
    var prefersMini: Bool {
        switch self {
        case .polish, .cheatsheet: return true
        case .reply, .rePolish, .batchPolish, .vision, .general: return false
        }
    }
}

/// Errors specific to LLM providers.
enum LLMProviderError: Error, LocalizedError {
    case notConfigured(String)
    case requestFailed(statusCode: Int, body: String)
    case networkError(Error)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let reason): return "LLM not configured: \(reason)"
        case .requestFailed(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .networkError(let err): return "Network: \(err.localizedDescription)"
        case .parseError(let msg): return "Parse error: \(msg)"
        }
    }
}

/// Protocol for LLM backends. Both cloud (Azure OpenAI) and local (MLX) conform.
protocol LLMProvider: Sendable {
    /// Human-readable name for UI display.
    var displayName: String { get }

    /// Whether this provider is ready to handle requests.
    var isConfigured: Bool { get }

    /// Generate a completion. Throws on failure.
    func generate(prompt: String, maxTokens: Int) async throws -> LLMResult
}

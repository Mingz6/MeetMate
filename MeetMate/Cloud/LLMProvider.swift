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

import Foundation

/// Azure OpenAI Chat Completions provider.
///
/// Uses the chat completions endpoint:
/// `POST {endpoint}/openai/deployments/{deployment}/chat/completions?api-version=2024-10-21`
///
/// Auth: `api-key` header (same as worker-center pattern).
/// Credentials stored in Keychain via `KeychainHelper`.
final class AzureOpenAIProvider: LLMProvider, @unchecked Sendable {

    let displayName = "Azure OpenAI"

    private let session: URLSession
    private let apiVersion = "2024-10-21"

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    var isConfigured: Bool {
        guard let endpoint = KeychainHelper.get(forKey: KeychainHelper.azureEndpointKey),
              let apiKey = KeychainHelper.get(forKey: KeychainHelper.azureAPIKeyKey),
              let deployment = KeychainHelper.get(forKey: KeychainHelper.azureDeploymentKey) else {
            return false
        }
        return !endpoint.isEmpty && !apiKey.isEmpty && !deployment.isEmpty
    }

    func generate(prompt: String, maxTokens: Int) async throws -> LLMResult {
        guard let endpoint = KeychainHelper.get(forKey: KeychainHelper.azureEndpointKey),
              let apiKey = KeychainHelper.get(forKey: KeychainHelper.azureAPIKeyKey),
              let deployment = KeychainHelper.get(forKey: KeychainHelper.azureDeploymentKey) else {
            throw LLMProviderError.notConfigured("Azure OpenAI endpoint, API key, or deployment missing from Keychain")
        }

        let url = buildURL(endpoint: endpoint, deployment: deployment)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ChatCompletionRequest(
            messages: [.init(role: "user", content: prompt)],
            max_tokens: maxTokens,
            temperature: 0.3
        )
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMProviderError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMProviderError.parseError("Non-HTTP response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(binary)"
            throw LLMProviderError.requestFailed(statusCode: httpResponse.statusCode, body: body)
        }

        return try parseResponse(data)
    }

    /// Streaming generation — yields partial text chunks as they arrive.
    func generateStreaming(prompt: String, maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let endpoint = KeychainHelper.get(forKey: KeychainHelper.azureEndpointKey),
                          let apiKey = KeychainHelper.get(forKey: KeychainHelper.azureAPIKeyKey),
                          let deployment = KeychainHelper.get(forKey: KeychainHelper.azureDeploymentKey) else {
                        throw LLMProviderError.notConfigured("Azure OpenAI not configured")
                    }

                    let url = buildURL(endpoint: endpoint, deployment: deployment)
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue(apiKey, forHTTPHeaderField: "api-key")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    let body = ChatCompletionRequest(
                        messages: [.init(role: "user", content: prompt)],
                        max_tokens: maxTokens,
                        temperature: 0.3,
                        stream: true
                    )
                    request.httpBody = try JSONEncoder().encode(body)

                    let (bytes, response) = try await self.session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse,
                          (200..<300).contains(httpResponse.statusCode) else {
                        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                        throw LLMProviderError.requestFailed(statusCode: code, body: "streaming failed")
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }

                        guard let jsonData = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(StreamChunk.self, from: jsonData),
                              let delta = chunk.choices.first?.delta.content else { continue }
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private

    private func buildURL(endpoint: String, deployment: String) -> URL {
        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        let urlString = "\(base)/openai/deployments/\(deployment)/chat/completions?api-version=\(apiVersion)"
        return URL(string: urlString)!
    }

    private func parseResponse(_ data: Data) throws -> LLMResult {
        let decoded: ChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "(binary)"
            throw LLMProviderError.parseError("JSON decode failed: \(error). Raw: \(raw.prefix(300))")
        }

        guard let choice = decoded.choices.first else {
            throw LLMProviderError.parseError("No choices in response")
        }

        let usage: TokenUsage?
        if let u = decoded.usage {
            usage = TokenUsage(promptTokens: u.prompt_tokens, completionTokens: u.completion_tokens)
        } else {
            usage = nil
        }

        return LLMResult(text: choice.message.content, usage: usage)
    }
}

// MARK: - Request / Response models

private struct ChatCompletionRequest: Encodable {
    let messages: [Message]
    let max_tokens: Int
    let temperature: Double
    var stream: Bool = false

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Decodable {
        let message: Message
    }
    struct Message: Decodable {
        let content: String
    }
    struct Usage: Decodable {
        let prompt_tokens: Int
        let completion_tokens: Int
    }
}

private struct StreamChunk: Decodable {
    let choices: [StreamChoice]
    struct StreamChoice: Decodable {
        let delta: Delta
    }
    struct Delta: Decodable {
        let content: String?
    }
}

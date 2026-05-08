import Foundation

/// Writes per-call JSONL records for cost tracking.
/// Format matches worker-center's `ai_cost_log.py` schema so it can be ingested directly.
///
/// Log location: ~/Documents/MeetMate/ai-cost/ai-cost-YYYY-MM.jsonl
final class CostLogger: Sendable {

    static let shared = CostLogger()

    private let logDir: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        logDir = docs.appendingPathComponent("MeetMate/ai-cost", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    }

    /// Log a single Azure OpenAI API call.
    func log(
        deployment: String,
        operation: String,
        promptTokens: Int,
        completionTokens: Int,
        durationMs: Int = 0,
        status: String = "ok"
    ) {
        let logDir = self.logDir
        let now = ISO8601DateFormatter.shared.string(from: Date())
        let (costUSD, costCAD) = Self.calculateCost(
            deployment: deployment,
            promptTokens: promptTokens,
            completionTokens: completionTokens
        )

        let record: [String: Any] = [
            "ts": now,
            "app": "meetmate",
            "deployment": deployment,
            "model": Self.resolveModel(deployment),
            "operation": operation,
            "ref": "",
            "prompt_tokens": promptTokens,
            "completion_tokens": completionTokens,
            "cost_usd": costUSD,
            "cost_cad": costCAD,
            "duration_ms": durationMs,
            "status": status,
        ]

        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONSerialization.data(withJSONObject: record),
                  let line = String(data: data, encoding: .utf8) else { return }

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM"
            let fileName = "ai-cost-\(formatter.string(from: Date())).jsonl"
            let fileURL = logDir.appendingPathComponent(fileName)

            let lineData = (line + "\n").data(using: .utf8)!
            if FileManager.default.fileExists(atPath: fileURL.path) {
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    handle.seekToEndOfFile()
                    handle.write(lineData)
                    handle.closeFile()
                }
            } else {
                try? lineData.write(to: fileURL)
            }
        }
    }

    // MARK: - Pricing (mirrors worker-center/workers/ai_cost_log.py)

    private static let pricing: [String: (input: Double, output: Double)] = [
        "gpt-5.4": (2.50, 15.0),
        "gpt-5.4-mini": (0.75, 4.50),
        "gpt-5.4-nano": (0.20, 1.25),
    ]

    private static let deploymentToModel: [String: String] = [
        "neuro-ming-gpt": "gpt-5.4",
    ]

    private static let cadRate = 1.38

    private static func resolveModel(_ deployment: String) -> String {
        deploymentToModel[deployment.lowercased()] ?? deployment
    }

    private static func calculateCost(deployment: String, promptTokens: Int, completionTokens: Int) -> (Double, Double) {
        let model = resolveModel(deployment)
        guard let price = pricing[model] ?? pricing.first(where: { model.hasPrefix($0.key) })?.value else {
            return (0, 0)
        }
        let usd = (Double(promptTokens) / 1_000_000) * price.input
                + (Double(completionTokens) / 1_000_000) * price.output
        return (round(usd * 1_000_000) / 1_000_000, round(usd * cadRate * 1_000_000) / 1_000_000)
    }
}

// MARK: - Shared formatter

private extension ISO8601DateFormatter {
    static let shared: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

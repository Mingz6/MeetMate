import Foundation

/// Disk-backed queue for LLM jobs that failed due to network issues.
/// Jobs are serialized as JSON files in a `replay/` directory inside the session folder.
/// When cloud comes back online, drain the queue in FIFO order.
actor ReplayQueue {
    private let baseURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.baseURL = appSupport.appendingPathComponent("MeetMate/replay", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    /// Enqueue a failed job for later replay.
    func enqueue(_ job: ReplayJob) {
        let filename = "\(job.timestamp.timeIntervalSince1970)-\(job.taskType.rawValue).json"
        let fileURL = baseURL.appendingPathComponent(filename)
        do {
            let data = try encodeJob(job)
            try data.write(to: fileURL, options: .atomic)
            print("[ReplayQueue] enqueued \(job.taskType.rawValue) job")
        } catch {
            print("[ReplayQueue] failed to enqueue: \(error)")
        }
    }

    /// Get all pending jobs in FIFO order.
    func pending() -> [ReplayJob] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url -> ReplayJob? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decodeJob(data)
            }
    }

    /// Number of pending jobs.
    var count: Int {
        let files = try? FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)
        return files?.filter { $0.pathExtension == "json" }.count ?? 0
    }

    /// Remove a completed job from the queue.
    func remove(_ job: ReplayJob) {
        let filename = "\(job.timestamp.timeIntervalSince1970)-\(job.taskType.rawValue).json"
        let fileURL = baseURL.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Remove all pending jobs (e.g., on user reset).
    func clear() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            try? FileManager.default.removeItem(at: file)
        }
        print("[ReplayQueue] cleared all pending jobs")
    }

    // nonisolated to avoid main-actor-isolated Codable conformance warning in actor context
    nonisolated private func encodeJob(_ job: ReplayJob) throws -> Data {
        try JSONEncoder().encode(job)
    }

    nonisolated private func decodeJob(_ data: Data) throws -> ReplayJob {
        try JSONDecoder().decode(ReplayJob.self, from: data)
    }
}

// MARK: - Job model

struct ReplayJob: Codable, Sendable {
    let taskType: TaskType
    let prompt: String
    let maxTokens: Int
    let timestamp: Date

    enum TaskType: String, Codable, Sendable {
        case polish
        case cheatsheet
        case reply
    }
}

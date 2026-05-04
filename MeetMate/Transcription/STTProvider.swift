import Foundation
import AVFoundation

/// A single recognized speech segment from any STT backend.
struct STTSegment: Sendable {
    let text: String
    let startSec: Float
    let endSec: Float
    let isFinal: Bool
}

/// Errors from STT providers.
enum STTProviderError: Error, LocalizedError {
    case notConfigured(String)
    case connectionFailed(Error)
    case audioFormatError(String)
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let reason): return "STT not configured: \(reason)"
        case .connectionFailed(let err): return "Connection failed: \(err.localizedDescription)"
        case .audioFormatError(let msg): return "Audio format: \(msg)"
        case .recognitionFailed(let msg): return "Recognition failed: \(msg)"
        }
    }
}

/// Protocol for speech-to-text backends (cloud or local).
protocol STTProvider: AnyObject, Sendable {
    var displayName: String { get }
    var isConfigured: Bool { get }

    /// Start continuous recognition. Calls `onSegment` for each recognized segment.
    func startContinuousRecognition(
        onSegment: @escaping @Sendable (STTSegment) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) async throws

    /// Feed audio samples (16kHz mono Float32) to the recognizer.
    func ingestAudio(_ samples: [Float]) async

    /// Stop recognition and close connections.
    func stopContinuousRecognition() async
}

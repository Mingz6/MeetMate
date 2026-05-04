import Foundation
import AVFoundation

/// Which audio source produced a segment.
enum AudioSource: String, Codable, Sendable {
    case mic     // Local microphone (the user / in-room speakers)
    case system  // System audio loopback (remote participants via Zoom/Teams/etc.)
    case mixed   // Legacy mixed stream (local WhisperKit fallback)
}

/// A single recognized speech segment from any STT backend.
struct STTSegment: Sendable {
    let text: String
    let startSec: Float
    let endSec: Float
    let isFinal: Bool
    let source: AudioSource
    let speakerId: Int?  // Speaker diarization label (nil = not available)

    init(text: String, startSec: Float, endSec: Float, isFinal: Bool, source: AudioSource, speakerId: Int? = nil) {
        self.text = text
        self.startSec = startSec
        self.endSec = endSec
        self.isFinal = isFinal
        self.source = source
        self.speakerId = speakerId
    }
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

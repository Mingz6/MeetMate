import Foundation
import AVFoundation

/// Azure AI Speech real-time transcription via WebSocket.
///
/// Protocol: connects to `wss://{region}.stt.speech.microsoft.com/speech/recognition/conversation/cognitiveservices/v1`,
/// streams 16kHz 16-bit mono PCM audio in binary frames, receives JSON text frames with partial (hypothesis)
/// and final (phrase) recognition results.
///
/// No external SDK — pure URLSessionWebSocketTask.
final class AzureSpeechSTT: @unchecked Sendable {

    // MARK: - Configuration

    private let region: String
    private let apiKey: String
    private let language: String

    // MARK: - State

    private var webSocket: URLSessionWebSocketTask?
    private let session: URLSession
    private var onSegment: (@Sendable (STTSegment) -> Void)?
    private var onError: (@Sendable (Error) -> Void)?
    private var isRunning = false
    private let requestId = UUID().uuidString.replacingOccurrences(of: "-", with: "")

    /// Cumulative audio duration sent (for offset tracking).
    private var audioOffsetSec: Float = 0
    private let sampleRate: Float = 16_000

    /// Track total audio seconds sent for cost metering.
    private(set) var totalAudioSecondsSent: Float = 0

    /// Phrase list for vocabulary biasing. Set before calling startContinuousRecognition.
    var phraseList: [String] = []

    // MARK: - Init

    init(region: String, apiKey: String, language: String = "en-US") {
        self.region = region
        self.apiKey = apiKey
        self.language = language
        self.session = URLSession(configuration: .default)
    }

    /// Whether this provider has valid configuration.
    var isConfigured: Bool {
        !region.isEmpty && !apiKey.isEmpty
    }

    // MARK: - Public API

    func startContinuousRecognition(
        onSegment: @escaping @Sendable (STTSegment) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) async throws {
        guard isConfigured else {
            throw STTProviderError.notConfigured("Azure Speech region or API key missing")
        }
        guard !isRunning else { return }

        self.onSegment = onSegment
        self.onError = onError
        self.audioOffsetSec = 0
        self.totalAudioSecondsSent = 0

        let endpoint = "wss://\(region).stt.speech.microsoft.com/speech/recognition/conversation/cognitiveservices/v1?language=\(language)&format=detailed"
        guard let url = URL(string: endpoint) else {
            throw STTProviderError.notConfigured("Invalid endpoint URL")
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue(requestId, forHTTPHeaderField: "X-ConnectionId")

        let task = session.webSocketTask(with: request)
        self.webSocket = task
        task.resume()
        isRunning = true

        // Send speech.config message
        try await sendSpeechConfig()

        // Send phrase list if configured
        if !phraseList.isEmpty {
            try await sendSpeechContext()
        }

        // Start receive loop
        Task { [weak self] in
            await self?.receiveLoop()
        }

        print("[AzureSpeech] connected to \(region), language=\(language)")
    }

    /// Feed 16kHz mono Float32 audio samples.
    func ingestAudio(_ samples: [Float]) async {
        guard isRunning, let ws = webSocket else { return }

        let pcmData = float32ToPCM16(samples)
        let header = buildAudioHeader()
        var frame = Data()
        // Binary frame: 2-byte header length (big-endian) + header bytes + audio bytes
        let headerBytes = header.data(using: .utf8) ?? Data()
        var headerLen = UInt16(headerBytes.count).bigEndian
        frame.append(Data(bytes: &headerLen, count: 2))
        frame.append(headerBytes)
        frame.append(pcmData)

        do {
            try await ws.send(.data(frame))
            let sampleCount = Float(samples.count)
            audioOffsetSec += sampleCount / sampleRate
            totalAudioSecondsSent += sampleCount / sampleRate
        } catch {
            print("[AzureSpeech] send error: \(error)")
            onError?(error)
        }
    }

    func stopContinuousRecognition() async {
        guard isRunning else { return }
        isRunning = false

        // Send end-of-audio silence marker (empty audio message signals end)
        if let ws = webSocket {
            let header = buildAudioHeader()
            let headerBytes = header.data(using: .utf8) ?? Data()
            var frame = Data()
            var headerLen = UInt16(headerBytes.count).bigEndian
            frame.append(Data(bytes: &headerLen, count: 2))
            frame.append(headerBytes)
            // Empty audio payload = end of stream
            try? await ws.send(.data(frame))
            ws.cancel(with: .normalClosure, reason: nil)
        }
        webSocket = nil
        onSegment = nil
        onError = nil
        print("[AzureSpeech] stopped, total audio sent: \(String(format: "%.1f", totalAudioSecondsSent))s")
    }

    // MARK: - WebSocket Protocol

    private func sendSpeechConfig() async throws {
        let config: [String: Any] = [
            "context": [
                "system": [
                    "name": "MeetMate",
                    "version": "1.0",
                    "build": "macOS"
                ],
                "os": [
                    "platform": "macOS",
                    "name": "macOS",
                    "version": ProcessInfo.processInfo.operatingSystemVersionString
                ],
                "audio": [
                    "source": [
                        "connectivity": "Unknown",
                        "manufacturer": "Apple",
                        "model": "Built-in",
                        "type": "Microphones"
                    ]
                ]
            ]
        ]

        let body = try JSONSerialization.data(withJSONObject: config)
        let bodyStr = String(data: body, encoding: .utf8) ?? "{}"

        let headers = [
            "Path: speech.config",
            "X-RequestId: \(requestId)",
            "X-Timestamp: \(iso8601Timestamp())",
            "Content-Type: application/json"
        ].joined(separator: "\r\n")

        let message = "\(headers)\r\n\r\n\(bodyStr)"
        try await webSocket?.send(.string(message))
    }

    /// Send phrase list for vocabulary biasing via speech.context message.
    private func sendSpeechContext() async throws {
        let phrases = phraseList.prefix(500).map { ["text": $0] }
        let context: [String: Any] = [
            "phraseDetection": [
                "mode": "Conversation"
            ],
            "phraseList": [
                "phrases": phrases
            ]
        ]

        let body = try JSONSerialization.data(withJSONObject: context)
        let bodyStr = String(data: body, encoding: .utf8) ?? "{}"

        let headers = [
            "Path: speech.context",
            "X-RequestId: \(requestId)",
            "X-Timestamp: \(iso8601Timestamp())",
            "Content-Type: application/json"
        ].joined(separator: "\r\n")

        let message = "\(headers)\r\n\r\n\(bodyStr)"
        try await webSocket?.send(.string(message))
        print("[AzureSpeech] sent phrase list with \(phrases.count) terms")
    }

    private func buildAudioHeader() -> String {
        [
            "Path: audio",
            "X-RequestId: \(requestId)",
            "X-Timestamp: \(iso8601Timestamp())",
            "Content-Type: audio/x-wav"
        ].joined(separator: "\r\n")
    }

    private func receiveLoop() async {
        guard let ws = webSocket else { return }

        while isRunning {
            do {
                let message = try await ws.receive()
                switch message {
                case .string(let text):
                    handleTextMessage(text)
                case .data(let data):
                    // Server binary messages (rare for speech results)
                    if let text = String(data: data, encoding: .utf8) {
                        handleTextMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                if isRunning {
                    print("[AzureSpeech] receive error: \(error)")
                    onError?(error)
                    isRunning = false
                }
                break
            }
        }
    }

    private func handleTextMessage(_ raw: String) {
        // Messages have headers separated from body by \r\n\r\n
        let parts = raw.components(separatedBy: "\r\n\r\n")
        guard parts.count >= 2 else { return }

        let headerSection = parts[0]
        let body = parts.dropFirst().joined(separator: "\r\n\r\n")

        // Extract the Path header
        var path = ""
        for line in headerSection.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("path:") {
                path = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                break
            }
        }

        switch path {
        case "speech.hypothesis":
            parseHypothesis(body)
        case "speech.phrase":
            parsePhrase(body)
        case "speech.endDetected":
            print("[AzureSpeech] speech.endDetected")
        case "turn.end":
            print("[AzureSpeech] turn.end")
        case "speech.startDetected":
            print("[AzureSpeech] speech.startDetected")
        default:
            break
        }
    }

    private func parseHypothesis(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["Text"] as? String else { return }

        let offset = ticksToSeconds(obj["Offset"] as? Int64 ?? 0)
        let duration = ticksToSeconds(obj["Duration"] as? Int64 ?? 0)

        let segment = STTSegment(
            text: text,
            startSec: offset,
            endSec: offset + duration,
            isFinal: false
        )
        onSegment?(segment)
    }

    private func parsePhrase(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let status = obj["RecognitionStatus"] as? String ?? ""
        guard status == "Success" else {
            if status == "EndOfDictation" || status == "InitialSilenceTimeout" {
                // Not an error — just silence
                return
            }
            print("[AzureSpeech] recognition status: \(status)")
            return
        }

        // Use NBest[0].Display for best text, fall back to DisplayText
        var text = obj["DisplayText"] as? String ?? ""
        if let nbest = obj["NBest"] as? [[String: Any]], let first = nbest.first {
            text = first["Display"] as? String ?? text
        }

        guard !text.isEmpty else { return }

        let offset = ticksToSeconds(obj["Offset"] as? Int64 ?? 0)
        let duration = ticksToSeconds(obj["Duration"] as? Int64 ?? 0)

        let segment = STTSegment(
            text: text,
            startSec: offset,
            endSec: offset + duration,
            isFinal: true
        )
        onSegment?(segment)
    }

    // MARK: - Helpers

    /// Convert Float32 samples to 16-bit PCM Data.
    private func float32ToPCM16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var pcm = Int16(clamped * 32767)
            data.append(Data(bytes: &pcm, count: 2))
        }
        return data
    }

    /// Azure Speech uses 100-nanosecond ticks for offsets/durations.
    private func ticksToSeconds(_ ticks: Int64) -> Float {
        Float(ticks) / 10_000_000.0
    }

    private func iso8601Timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

// MARK: - STTProvider Conformance

extension AzureSpeechSTT: STTProvider {
    var displayName: String { "Azure AI Speech" }
}

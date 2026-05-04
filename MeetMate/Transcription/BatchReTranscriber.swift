import Foundation
import Combine
import AVFoundation
import WhisperKit

/// Re-transcribes saved audio files post-meeting using Azure Speech Fast Transcription API
/// or local WhisperKit (large-v3-turbo) when cloud is disabled.
///
/// Produces higher-quality results than live streaming because:
/// - Full audio context (no sliding window)
/// - Speaker diarization built in (cloud only)
/// - Full phrase list injected
/// - Word-level timestamps
///
/// Results are written to `transcript.batch.jsonl` in the session folder — never overwrites
/// the live transcript. Caller decides whether to accept the batch results.
@MainActor
final class BatchReTranscriber: ObservableObject {

    enum Status: Equatable {
        case idle
        case loading           // Loading/converting audio file
        case transcribing(progress: Float)  // 0.0–1.0
        case complete(segmentCount: Int)
        case failed(String)
    }

    enum Mode {
        case cloud   // Azure Fast Transcription API
        case local   // WhisperKit large-v3-turbo
    }

    @Published private(set) var status: Status = .idle

    private let region: String
    private let apiKey: String
    private let language: String
    private var phraseList: [String] = []
    private var collectedSegments: [BatchSegment] = []

    struct BatchSegment: Codable {
        let startTime: TimeInterval
        let endTime: TimeInterval
        let text: String
        let confidence: Float?
        let speaker: Int?
    }

    /// Resolved mode — cloud if configured, local fallback otherwise.
    var mode: Mode {
        (!region.isEmpty && !apiKey.isEmpty) ? .cloud : .local
    }

    init(region: String, apiKey: String, language: String = "en-US") {
        self.region = region
        self.apiKey = apiKey
        self.language = language
    }

    /// Start batch re-transcription — routes to cloud or local depending on configuration.
    func reTranscribe(sessionFolder: URL, vocabulary: [String]) async {
        phraseList = vocabulary
        collectedSegments = []

        switch mode {
        case .cloud:
            await reTranscribeCloud(sessionFolder: sessionFolder)
        case .local:
            await reTranscribeLocal(sessionFolder: sessionFolder)
        }
    }

    // MARK: - Cloud path (Azure Fast Transcription API)

    private func reTranscribeCloud(sessionFolder: URL) async {
        status = .loading

        // Find audio file
        let micURL = sessionFolder.appendingPathComponent("mic.m4a")
        let systemURL = sessionFolder.appendingPathComponent("system.m4a")

        let audioURL: URL
        if FileManager.default.fileExists(atPath: micURL.path) {
            audioURL = micURL
        } else if FileManager.default.fileExists(atPath: systemURL.path) {
            audioURL = systemURL
        } else {
            status = .failed("No audio files found in session folder")
            return
        }

        // Convert to WAV (Fast Transcription API accepts wav/mp3/ogg/flac/m4a)
        // m4a should work directly — no conversion needed
        guard let audioData = try? Data(contentsOf: audioURL) else {
            status = .failed("Could not read audio file")
            return
        }

        let fileSizeMB = Double(audioData.count) / 1_048_576
        print("[Batch] loaded \(audioURL.lastPathComponent) (\(String(format: "%.1f", fileSizeMB)) MB)")

        guard audioData.count < 250 * 1_048_576 else {
            status = .failed("Audio file exceeds 250MB limit")
            return
        }

        status = .transcribing(progress: 0.1)

        // Call Fast Transcription API
        let endpoint = "https://\(region).api.cognitive.microsoft.com/speechtotext/transcriptions:transcribe?api-version=2025-10-15"
        guard let url = URL(string: endpoint) else {
            status = .failed("Invalid endpoint URL")
            return
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300 // 5 min for large files

        // Build definition JSON
        var definition: [String: Any] = [
            "locales": [language],
            "profanityFilterMode": "None",
            "diarization": [
                "maxSpeakers": 10
            ]
        ]
        if !phraseList.isEmpty {
            let phrases = phraseList.prefix(500).map { ["value": $0] }
            definition["customPhrases"] = [
                ["phrases": phrases]
            ]
        }

        guard let definitionData = try? JSONSerialization.data(withJSONObject: definition),
              let definitionString = String(data: definitionData, encoding: .utf8) else {
            status = .failed("Could not serialize definition")
            return
        }

        // Build multipart body
        var body = Data()
        // Definition part
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"definition\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json\r\n\r\n".data(using: .utf8)!)
        body.append(definitionString.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
        // Audio part
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"\(audioURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body
        status = .transcribing(progress: 0.3)

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await URLSession.shared.data(for: request)
        } catch {
            status = .failed("Network error: \(error.localizedDescription)")
            return
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            status = .failed("Invalid response")
            return
        }

        status = .transcribing(progress: 0.8)

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: responseData, encoding: .utf8) ?? "(binary)"
            print("[Batch] API error \(httpResponse.statusCode): \(body.prefix(500))")
            status = .failed("API error \(httpResponse.statusCode)")
            return
        }

        // Parse response
        guard let result = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let phrases = result["phrases"] as? [[String: Any]] else {
            status = .failed("Could not parse transcription response")
            return
        }

        collectedSegments = phrases.compactMap { phrase in
            guard let text = phrase["text"] as? String, !text.isEmpty else { return nil }
            let offsetMs = phrase["offsetMilliseconds"] as? Int ?? 0
            let durationMs = phrase["durationMilliseconds"] as? Int ?? 0
            let confidence = phrase["confidence"] as? Float
            let speaker = phrase["speaker"] as? Int

            return BatchSegment(
                startTime: TimeInterval(offsetMs) / 1000.0,
                endTime: TimeInterval(offsetMs + durationMs) / 1000.0,
                text: text,
                confidence: confidence,
                speaker: speaker
            )
        }

        // Write results
        await writeResults(to: sessionFolder)

        status = .complete(segmentCount: collectedSegments.count)
        print("[Batch] Fast Transcription complete: \(collectedSegments.count) segments, speakers detected: \(uniqueSpeakerCount)")
    }

    // MARK: - Local path (WhisperKit large-v3-turbo)

    private func reTranscribeLocal(sessionFolder: URL) async {
        status = .loading

        let micURL = sessionFolder.appendingPathComponent("mic.m4a")
        let systemURL = sessionFolder.appendingPathComponent("system.m4a")

        let audioURL: URL
        if FileManager.default.fileExists(atPath: micURL.path) {
            audioURL = micURL
        } else if FileManager.default.fileExists(atPath: systemURL.path) {
            audioURL = systemURL
        } else {
            status = .failed("No audio files found in session folder")
            return
        }

        print("[Batch] local mode — loading WhisperKit large-v3-turbo for \(audioURL.lastPathComponent)")
        status = .transcribing(progress: 0.1)

        do {
            let modelName = "openai_whisper-large-v3-turbo"
            let config = WhisperKitConfig(
                model: modelName,
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: false,
                download: true
            )
            let whisper = try await WhisperKit(config)
            try await whisper.loadModels()
            status = .transcribing(progress: 0.3)

            // Build prompt from vocabulary for biasing
            var promptTokens: [Int]?
            if !phraseList.isEmpty, let tokenizer = whisper.tokenizer {
                let prompt = phraseList.prefix(50).joined(separator: ", ")
                let tokens = tokenizer.encode(text: prompt)
                promptTokens = tokens.isEmpty ? nil : Array(tokens.prefix(200))
            }

            let opts = DecodingOptions(
                verbose: false,
                task: .transcribe,
                language: "en",
                temperature: 0.0,
                temperatureFallbackCount: 3,
                sampleLength: 224,
                usePrefillPrompt: true,
                skipSpecialTokens: true,
                withoutTimestamps: false,
                promptTokens: promptTokens,
                suppressBlank: true,
                compressionRatioThreshold: 2.4,
                logProbThreshold: -1.0,
                noSpeechThreshold: 0.6
            )

            status = .transcribing(progress: 0.5)
            let results = try await whisper.transcribe(audioPath: audioURL.path, decodeOptions: opts)
            status = .transcribing(progress: 0.9)

            guard let result = results.first else {
                status = .failed("WhisperKit returned no results")
                return
            }

            collectedSegments = result.segments.compactMap { seg in
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return BatchSegment(
                    startTime: TimeInterval(seg.start),
                    endTime: TimeInterval(seg.end),
                    text: text,
                    confidence: seg.avgLogprob > -1.0 ? Float(exp(seg.avgLogprob)) : nil,
                    speaker: nil // Local WhisperKit doesn't do diarization
                )
            }

            await writeResults(to: sessionFolder)
            status = .complete(segmentCount: collectedSegments.count)
            print("[Batch] local transcription complete: \(collectedSegments.count) segments")
        } catch {
            status = .failed("Local transcription failed: \(error.localizedDescription)")
            print("[Batch] local error: \(error)")
        }
    }

    /// The batch transcript as a single string.
    var batchTranscriptText: String {
        collectedSegments.map(\.text).joined(separator: " ")
    }

    /// Segment count from the last batch run.
    var segmentCount: Int { collectedSegments.count }

    /// Number of unique speakers detected.
    var uniqueSpeakerCount: Int {
        Set(collectedSegments.compactMap(\.speaker)).count
    }

    /// Segments with speaker labels for UI display.
    var segments: [BatchSegment] { collectedSegments }

    // MARK: - File I/O

    private func writeResults(to sessionFolder: URL) async {
        let url = sessionFolder.appendingPathComponent("transcript.batch.jsonl")
        let encoder = JSONEncoder()

        var lines: [String] = []
        for segment in collectedSegments {
            if let data = try? encoder.encode(segment),
               let line = String(data: data, encoding: .utf8) {
                lines.append(line)
            }
        }

        let content = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try? content.write(to: url, atomically: true, encoding: .utf8)
        print("[Batch] wrote \(lines.count) segments to transcript.batch.jsonl")
    }
}

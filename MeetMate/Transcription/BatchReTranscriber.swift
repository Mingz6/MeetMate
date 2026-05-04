import Foundation
import Combine
import AVFoundation

/// Re-transcribes saved audio files post-meeting using a fresh Azure Speech WebSocket
/// connection with full phrase list. Produces higher-quality results than live streaming
/// because: no network jitter, complete audio (no VAD gaps), full phrase list injected.
///
/// Results are written to `transcript.batch.jsonl` in the session folder — never overwrites
/// the live transcript. Caller decides whether to accept the batch results.
@MainActor
final class BatchReTranscriber: ObservableObject {

    enum Status: Equatable {
        case idle
        case loading           // Loading audio file
        case transcribing(progress: Float)  // 0.0–1.0
        case complete(segmentCount: Int)
        case failed(String)
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
        let speaker: String?
    }

    init(region: String, apiKey: String, language: String = "en-US") {
        self.region = region
        self.apiKey = apiKey
        self.language = language
    }

    /// Start batch re-transcription of saved audio files.
    /// - Parameters:
    ///   - sessionFolder: Path to session folder containing mic.m4a / system.m4a
    ///   - vocabulary: Phrase list for biasing
    func reTranscribe(sessionFolder: URL, vocabulary: [String]) async {
        guard !region.isEmpty, !apiKey.isEmpty else {
            status = .failed("Azure Speech not configured")
            return
        }

        phraseList = vocabulary
        collectedSegments = []
        status = .loading

        // Load and decode audio
        let micURL = sessionFolder.appendingPathComponent("mic.m4a")
        let systemURL = sessionFolder.appendingPathComponent("system.m4a")

        // Try mic first, fall back to system
        let audioURL: URL
        if FileManager.default.fileExists(atPath: micURL.path) {
            audioURL = micURL
        } else if FileManager.default.fileExists(atPath: systemURL.path) {
            audioURL = systemURL
        } else {
            status = .failed("No audio files found in session folder")
            return
        }

        guard let samples = await loadAudioAs16kMono(url: audioURL) else {
            status = .failed("Could not decode audio file")
            return
        }

        let totalDuration = Float(samples.count) / 16_000.0
        print("[Batch] loaded \(String(format: "%.1f", totalDuration))s of audio from \(audioURL.lastPathComponent)")

        // Create a fresh Azure Speech connection and pump audio
        status = .transcribing(progress: 0)
        let stt = AzureSpeechSTT(region: region, apiKey: apiKey, language: language)
        stt.phraseList = phraseList

        let segmentCollector = SegmentCollector()

        do {
            try await stt.startContinuousRecognition(
                onSegment: { segment in
                    Task { @MainActor [weak segmentCollector] in
                        segmentCollector?.add(segment)
                    }
                },
                onError: { [weak self] error in
                    Task { @MainActor in
                        print("[Batch] error during re-transcription: \(error)")
                        self?.status = .failed(error.localizedDescription)
                    }
                }
            )
        } catch {
            status = .failed("Failed to connect: \(error.localizedDescription)")
            return
        }

        // Pump audio in chunks (~0.5s per chunk, faster than real-time)
        let chunkSize = 8000 // 0.5s at 16kHz
        let totalChunks = (samples.count + chunkSize - 1) / chunkSize

        for i in 0..<totalChunks {
            let start = i * chunkSize
            let end = min(start + chunkSize, samples.count)
            let chunk = Array(samples[start..<end])

            await stt.ingestAudio(chunk)

            // Update progress
            let progress = Float(i + 1) / Float(totalChunks)
            status = .transcribing(progress: progress)

            // Small delay to avoid overwhelming the WebSocket (4x real-time)
            if i % 8 == 7 {
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms every 4s of audio
            }
        }

        // Signal end and wait for final results
        await stt.stopContinuousRecognition()

        // Give a moment for final results to arrive
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Collect results
        collectedSegments = segmentCollector.segments.map { seg in
            BatchSegment(
                startTime: TimeInterval(seg.startSec),
                endTime: TimeInterval(seg.endSec),
                text: seg.text,
                confidence: nil,
                speaker: nil
            )
        }

        // Write results
        await writeResults(to: sessionFolder)

        status = .complete(segmentCount: collectedSegments.count)
        print("[Batch] re-transcription complete: \(collectedSegments.count) segments")
    }

    /// The batch transcript as a single string.
    var batchTranscriptText: String {
        collectedSegments.map(\.text).joined(separator: " ")
    }

    /// Segment count from the last batch run.
    var segmentCount: Int { collectedSegments.count }

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

    // MARK: - Audio Loading

    private func loadAudioAs16kMono(url: URL) async -> [Float]? {
        let asset = AVURLAsset(url: url)

        guard let reader: AVAssetReader = try? AVAssetReader(asset: asset) else { return nil }

        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(output)

        guard reader.startReading() else {
            print("[Batch] failed to start reading: \(reader.error?.localizedDescription ?? "unknown")")
            return nil
        }

        var samples: [Float] = []
        samples.reserveCapacity(16_000 * 60 * 30) // Pre-allocate for ~30 min

        while let buffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            var data = Data(count: length)
            data.withUnsafeMutableBytes { ptr in
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
            }
            // Convert Data to [Float]
            let floatCount = length / MemoryLayout<Float>.size
            let floats = data.withUnsafeBytes { ptr in
                Array(ptr.bindMemory(to: Float.self).prefix(floatCount))
            }
            samples.append(contentsOf: floats)
        }

        return samples.isEmpty ? nil : samples
    }
}

// MARK: - Segment Collector

/// Thread-safe collector for segments arriving from the WebSocket callback.
@MainActor
private final class SegmentCollector {
    var segments: [STTSegment] = []

    func add(_ segment: STTSegment) {
        guard segment.isFinal, !segment.text.isEmpty else { return }
        segments.append(segment)
    }
}

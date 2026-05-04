import Foundation
import Combine
@preconcurrency import AVFoundation
#if os(iOS)
import UIKit
#endif
import WhisperKit

/// Whisper model tier picked from device class. Bigger = better accuracy, slower, more disk.
enum WhisperModelTier {
    static func recommendedModelName() -> String {
        #if os(macOS)
        return "openai_whisper-large-v3"
        #elseif os(iOS)
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        if isPad && ramGB >= 12 { return "openai_whisper-small" }   // M-chip iPad
        if isPad { return "openai_whisper-base" }                    // older iPad
        return ramGB >= 8 ? "openai_whisper-base" : "openai_whisper-tiny"
        #else
        return "openai_whisper-base"
        #endif
    }
}

/// Streaming transcription with sliding-window + confirmed/unconfirmed segments.
///
/// Algorithm (mirrors WhisperKit's `AudioStreamTranscriber` and the OpenAI/Deepgram/AssemblyAI
/// real-time pattern):
/// 1. Mic + system audio is downsampled to 16 kHz mono and appended to a rolling sample buffer.
/// 2. Every ~1.5s a background loop runs `whisperKit.transcribe` on the buffer with
///    `clipTimestamps: [lastConfirmedSec]` so Whisper only re-decodes the un-confirmed tail.
/// 3. Returned segments are split: all but the last `requiredForConfirmation` (=2) are
///    promoted to `confirmedTranscript` (immutable), the trailing 2 stay in `unconfirmedText`
///    (will be re-emitted next cycle and may shift as more audio arrives — the live "interim" feel).
/// 4. Once a segment confirms, `lastConfirmedSec` advances so the next decode starts there.
/// 5. Buffer is purged when it grows past 90s; confirmed pointer + a `purgedDurationSec` offset
///    keep absolute time consistent.
@MainActor
final class TranscriptionService: ObservableObject {
    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var confirmedTranscript: String = ""
    @Published private(set) var unconfirmedText: String = ""
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var modelStatus: String = "not loaded"

    /// Set by the view layer before starting. Segments flush to disk on confirm.
    var sessionStorage: SessionStorage?

    private var whisperKit: WhisperKit?

    private var samples: [Float] = []
    private var lastBufferSize: Int = 0
    private var purgedDurationSec: Float = 0
    private var lastConfirmedSec: Float = 0
    private var meetingStartTime: Date?

    private let targetSampleRate: Float = 16_000
    private let stepIntervalSec: Double = 1.5
    private let minNewAudioSec: Float = 1.0
    private let requiredForConfirmation: Int = 2
    private let vadRmsThreshold: Float = 0.005
    private let maxBufferSec: Float = 90
    private let retainAfterPurgeSec: Float = 30
    private let preConfirmContextSec: Float = 5

    private var streamTask: Task<Void, Never>?
    private var sessionToken: Int = 0

    init() {}

    func loadModel() async throws {
        let modelName = WhisperModelTier.recommendedModelName()
        print("[Whisper] loading model \(modelName) (first run downloads model files)…")
        modelStatus = "loading…"
        let config = WhisperKitConfig(
            model: modelName,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: false,
            download: true
        )
        let kit = try await WhisperKit(config)
        try await kit.loadModels()
        whisperKit = kit
        modelStatus = "ready"
        print("[Whisper] model ready")
    }

    func ingest(_ buffer: AVAudioPCMBuffer) {
        if meetingStartTime == nil { meetingStartTime = Date() }
        guard let downs = downsampleToMono16k(buffer) else { return }
        samples.append(contentsOf: downs)
        if streamTask == nil, whisperKit != nil {
            startStreamLoop()
        }
    }

    func reset() {
        sessionToken &+= 1
        liveTranscript = ""
        confirmedTranscript = ""
        unconfirmedText = ""
        segments = []
        samples = []
        lastBufferSize = 0
        purgedDurationSec = 0
        lastConfirmedSec = 0
        meetingStartTime = nil
        sessionStorage = nil
        streamTask?.cancel()
        streamTask = nil
    }

    private func startStreamLoop() {
        streamTask = Task { [weak self] in
            await self?.streamLoop()
        }
    }

    private func streamLoop() async {
        let stepNanos = UInt64(stepIntervalSec * 1_000_000_000)
        let minNewSamples = Int(targetSampleRate * minNewAudioSec)

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: stepNanos)

            let newSampleCount = samples.count - lastBufferSize
            guard newSampleCount >= minNewSamples else { continue }

            let newPortion = Array(samples.suffix(newSampleCount))
            if computeRMS(newPortion) < vadRmsThreshold {
                lastBufferSize = samples.count
                continue
            }
            lastBufferSize = samples.count

            await runStreamingTranscribe()
            maybePurge()
        }
    }

    private func runStreamingTranscribe() async {
        guard let whisperKit else { return }
        let snapshot = samples
        let relativeStart = max(0, lastConfirmedSec - purgedDurationSec)
        let token = sessionToken

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
            clipTimestamps: [relativeStart],
            suppressBlank: true,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.6
        )

        do {
            let results = try await whisperKit.transcribe(audioArray: snapshot, decodeOptions: opts)
            guard let first = results.first else { return }
            guard token == sessionToken, !Task.isCancelled else {
                print("[Whisper] dropping stale segments from prior session")
                return
            }
            await applySegments(first.segments)
        } catch {
            print("[Whisper] stream error:", error)
        }
    }

    private func applySegments(_ rawSegments: [TranscriptionSegment]) async {
        let cleaned = rawSegments.compactMap { seg -> (TranscriptionSegment, String)? in
            let text = stripNoise(seg.text)
            return text.isEmpty ? nil : (seg, text)
        }
        guard !cleaned.isEmpty else {
            unconfirmedText = ""
            updateLive()
            return
        }

        if cleaned.count > requiredForConfirmation {
            let toConfirm = Array(cleaned.prefix(cleaned.count - requiredForConfirmation))
            let trailing = Array(cleaned.suffix(requiredForConfirmation))

            for (seg, text) in toConfirm {
                let absStart = Float(seg.start) + purgedDurationSec
                let absEnd = Float(seg.end) + purgedDurationSec
                guard absEnd > lastConfirmedSec else { continue }
                // Trim boundary-overlapping segments — Whisper sometimes re-segments around
                // lastConfirmedSec and emits a segment that starts before the confirm boundary.
                // Re-appending the whole text would duplicate words. Skip the whole segment;
                // the next cycle will pick up content past the new boundary.
                if absStart < lastConfirmedSec - 0.1 {
                    print("[Whisper] skipping overlap segment [\(absStart)–\(absEnd)] (boundary \(lastConfirmedSec))")
                    continue
                }
                appendConfirmed(text: text, startSec: absStart, endSec: absEnd)
                lastConfirmedSec = absEnd
            }
            unconfirmedText = trailing.map { $0.1 }.joined(separator: " ")
        } else {
            unconfirmedText = cleaned.map { $0.1 }.joined(separator: " ")
        }
        updateLive()
    }

    private func appendConfirmed(text: String, startSec: Float, endSec: Float) {
        let prefix = confirmedTranscript.isEmpty ? "" : " "
        confirmedTranscript += prefix + text
        let segment = TranscriptSegment(
            startTime: TimeInterval(startSec),
            endTime: TimeInterval(endSec),
            text: text
        )
        segments.append(segment)

        sessionStorage?.appendSegment(SegmentRecord(
            startTime: TimeInterval(startSec),
            endTime: TimeInterval(endSec),
            text: text,
            speaker: nil
        ))

        print("[Whisper ✓] \(text)")
    }

    private func updateLive() {
        if unconfirmedText.isEmpty {
            liveTranscript = confirmedTranscript
        } else if confirmedTranscript.isEmpty {
            liveTranscript = unconfirmedText
        } else {
            liveTranscript = confirmedTranscript + " " + unconfirmedText
        }
    }

    private func maybePurge() {
        let bufferDurationSec = Float(samples.count) / targetSampleRate
        guard bufferDurationSec > maxBufferSec else { return }

        let dropFromHead = bufferDurationSec - retainAfterPurgeSec
        let dropSamples = Int(dropFromHead * targetSampleRate)
        guard dropSamples > 0, dropSamples < samples.count else { return }

        // Don't purge into the un-confirmed region — leave a context cushion before lastConfirmedSec
        let safeAbsoluteCut = lastConfirmedSec - preConfirmContextSec
        let safeRelativeCut = safeAbsoluteCut - purgedDurationSec
        let safeMaxDropSec = max(0, safeRelativeCut)
        let safeMaxDropSamples = Int(safeMaxDropSec * targetSampleRate)
        let actualDrop = min(dropSamples, safeMaxDropSamples)
        guard actualDrop > 0 else { return }

        samples.removeFirst(actualDrop)
        lastBufferSize = max(0, lastBufferSize - actualDrop)
        purgedDurationSec += Float(actualDrop) / targetSampleRate
    }

    private func computeRMS(_ s: [Float]) -> Float {
        guard !s.isEmpty else { return 0 }
        var sum: Float = 0
        for v in s { sum += v * v }
        return (sum / Float(s.count)).squareRoot()
    }

    /// Whisper hallucinates labels like [Music], [BLANK_AUDIO], (inaudible), >>, etc. on silent or low-energy chunks.
    private func stripNoise(_ s: String) -> String {
        var out = s
        let patterns = [
            #"\[[^\]]+\]"#,        // [Music], [BLANK_AUDIO], [inaudible]
            #"\([^\)]+\)"#,         // (inaudible), (silence)
            #"^[>\s]+"#,             // leading >> markers
            #"\s{2,}"#                // collapse whitespace
        ]
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)

        let hallucinated: Set<String> = [
            "thank you.", "thank you", "thanks for watching.", "thanks for watching",
            "you", "you.", ".", "-", "—", "thanks.", "thanks",
            "bye.", "bye", "okay.", "okay"
        ]
        if hallucinated.contains(out.lowercased()) { return "" }
        return out
    }

    private func downsampleToMono16k(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let inputFormat = buffer.format as AVAudioFormat? else { return nil }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(targetSampleRate),
            channels: 1,
            interleaved: false
        ) else { return nil }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else { return nil }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, statusFlag in
            if consumed {
                statusFlag.pointee = .noDataNow
                return nil
            }
            consumed = true
            statusFlag.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil,
              let channelData = outputBuffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channelData, count: Int(outputBuffer.frameLength)))
    }
}

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
/// Supports two STT backends:
/// - **Cloud** (Azure AI Speech): streams audio over WebSocket, receives partial/final results.
///   Client-side VAD gate filters silence before sending (saves cost).
/// - **Local** (WhisperKit): sliding-window transcription on-device.
///
/// The public interface (`liveTranscript`, `confirmedTranscript`, `unconfirmedText`, `segments`)
/// is the same regardless of backend — consumers don't know or care which is active.
@MainActor
final class TranscriptionService: ObservableObject {

    // MARK: - STT Mode

    enum STTMode: String {
        case cloud       // Azure AI Speech via WebSocket
        case local       // WhisperKit on-device
        case recordingOnly  // No STT — audio still saved to disk
    }

    @Published private(set) var sttMode: STTMode = .local
    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var confirmedTranscript: String = ""
    @Published private(set) var unconfirmedText: String = ""
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var modelStatus: String = "not loaded"

    /// Set by the view layer before starting. Segments flush to disk on confirm.
    var sessionStorage: SessionStorage?

    // MARK: - Cloud STT

    private var cloudSTTMic: AzureSpeechSTT?
    private var cloudSTTSystem: AzureSpeechSTT?
    let vadGate = VADGate()
    private let vadGateSystem = VADGate()

    /// Vocabulary terms for STT biasing (from context + user edits).
    var vocabularyTerms: [String] = []

    /// Total seconds of audio sent to cloud STT this session (both streams combined).
    var cloudAudioSecondsSent: Float {
        (cloudSTTMic?.totalAudioSecondsSent ?? 0) + (cloudSTTSystem?.totalAudioSecondsSent ?? 0)
    }

    // MARK: - Local WhisperKit

    // MARK: - Local WhisperKit

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

    // MARK: - Mode Resolution

    /// Configure cloud STT. Creates two recognizer instances: one for mic, one for system audio.
    func configureCloudSTT(region: String, apiKey: String, language: String = "en-US") {
        cloudSTTMic = AzureSpeechSTT(region: region, apiKey: apiKey, language: language, audioSource: .mic)
        cloudSTTSystem = AzureSpeechSTT(region: region, apiKey: apiKey, language: language, audioSource: .system)
    }

    /// Resolve which STT mode to use based on configuration and network.
    func resolveMode(networkAvailable: Bool, cloudAvailable: Bool) {
        if let mic = cloudSTTMic, mic.isConfigured, networkAvailable, cloudAvailable {
            sttMode = .cloud
            modelStatus = "cloud ready"
        } else if whisperKit != nil {
            sttMode = .local
            modelStatus = "ready"
        } else {
            sttMode = .recordingOnly
            modelStatus = "recording only"
        }
        print("[STT] mode resolved: \(sttMode.rawValue)")
    }

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

    /// Ingest mic audio — routed to the mic cloud recognizer or local fallback.
    func ingestMic(_ buffer: AVAudioPCMBuffer) {
        if meetingStartTime == nil { meetingStartTime = Date() }
        guard let downs = downsampleToMono16k(buffer) else { return }

        switch sttMode {
        case .cloud:
            if let passed = vadGate.process(downs) {
                Task { [weak self] in
                    await self?.cloudSTTMic?.ingestAudio(passed)
                }
            }
        case .local:
            // Local WhisperKit gets all audio (mixed) — mic feeds in here
            samples.append(contentsOf: downs)
            if streamTask == nil, whisperKit != nil {
                startStreamLoop()
            }
        case .recordingOnly:
            break
        }
    }

    /// Ingest system audio (ScreenCaptureKit loopback) — routed to the system cloud recognizer.
    /// Falls through to local WhisperKit buffer (mixed) in local mode.
    func ingestSystem(_ buffer: AVAudioPCMBuffer) {
        if meetingStartTime == nil { meetingStartTime = Date() }
        guard let downs = downsampleToMono16k(buffer) else { return }

        switch sttMode {
        case .cloud:
            if let passed = vadGateSystem.process(downs) {
                Task { [weak self] in
                    await self?.cloudSTTSystem?.ingestAudio(passed)
                }
            }
        case .local:
            // Local WhisperKit gets all audio mixed together
            samples.append(contentsOf: downs)
            if streamTask == nil, whisperKit != nil {
                startStreamLoop()
            }
        case .recordingOnly:
            break
        }
    }

    /// Legacy single-stream ingest. Used by iOS (mic-only) or any path that doesn't separate streams.
    func ingest(_ buffer: AVAudioPCMBuffer) {
        ingestMic(buffer)
    }

    /// Start cloud continuous recognition on both mic and system recognizers.
    func startCloudRecognition() async {
        guard sttMode == .cloud else { return }
        vadGate.reset()
        vadGateSystem.reset()

        // Inject vocabulary terms for phrase list biasing on both recognizers
        cloudSTTMic?.phraseList = vocabularyTerms
        cloudSTTSystem?.phraseList = vocabularyTerms

        let segmentHandler: @Sendable (STTSegment) -> Void = { [weak self] segment in
            Task { @MainActor [weak self] in
                self?.handleCloudSegment(segment)
            }
        }
        let errorHandler: @Sendable (Error) -> Void = { [weak self] error in
            Task { @MainActor [weak self] in
                print("[STT Cloud] error: \(error)")
                if self?.whisperKit != nil {
                    self?.sttMode = .local
                    self?.modelStatus = "ready (fallback)"
                    print("[STT] fell back to local WhisperKit")
                } else {
                    self?.sttMode = .recordingOnly
                    self?.modelStatus = "recording only"
                }
            }
        }

        // Start mic recognizer
        if let mic = cloudSTTMic {
            do {
                try await mic.startContinuousRecognition(onSegment: segmentHandler, onError: errorHandler)
            } catch {
                print("[STT Cloud] mic start failed: \(error)")
            }
        }

        // Start system recognizer
        if let sys = cloudSTTSystem {
            do {
                try await sys.startContinuousRecognition(onSegment: segmentHandler, onError: errorHandler)
            } catch {
                print("[STT Cloud] system start failed: \(error)")
            }
        }

        // If both failed, fall back
        if cloudSTTMic == nil && cloudSTTSystem == nil {
            if whisperKit != nil {
                sttMode = .local
                modelStatus = "ready (fallback)"
            } else {
                sttMode = .recordingOnly
                modelStatus = "recording only"
            }
        }
    }

    /// Stop cloud recognition on both streams.
    func stopCloudRecognition() async {
        await cloudSTTMic?.stopContinuousRecognition()
        await cloudSTTSystem?.stopContinuousRecognition()
    }

    /// Replace the confirmed transcript with a batch-processed version.
    /// Used when user accepts the offline re-transcription results.
    func replaceConfirmedTranscript(with text: String) {
        confirmedTranscript = text
        unconfirmedText = ""
        updateLive()
    }

    /// Replace the segment list with batch re-transcription results (which carry speaker IDs).
    /// This gives the polisher access to diarization data for future polish cycles.
    func replaceSegments(with batchSegments: [BatchReTranscriber.BatchSegment]) {
        segments = batchSegments.map { seg in
            let segment = TranscriptSegment(
                startTime: seg.startTime,
                endTime: seg.endTime,
                text: seg.text,
                speaker: seg.speaker.map { "Speaker \($0)" }
            )
            return segment
        }
        confirmedTranscript = batchSegments.map(\.text).joined(separator: " ")
        unconfirmedText = ""
        updateLive()
    }

    private func handleCloudSegment(_ segment: STTSegment) {
        if segment.isFinal {
            let text = stripNoise(segment.text)
            guard !text.isEmpty else { return }
            appendConfirmed(text: text, startSec: segment.startSec, endSec: segment.endSec, source: segment.source)
            lastConfirmedSec = segment.endSec
            unconfirmedText = ""
            updateLive()
        } else {
            let text = stripNoise(segment.text)
            unconfirmedText = text
            updateLive()
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
        vadGate.reset()
        vadGateSystem.reset()

        // Stop both cloud STT recognizers
        Task { [weak self] in
            await self?.cloudSTTMic?.stopContinuousRecognition()
            await self?.cloudSTTSystem?.stopContinuousRecognition()
        }
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

        // Build prompt tokens from vocabulary for biasing
        let promptTokens: [Int]? = buildWhisperPromptTokens()

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
            promptTokens: promptTokens,
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

    private func appendConfirmed(text: String, startSec: Float, endSec: Float, source: AudioSource = .mixed) {
        let prefix = confirmedTranscript.isEmpty ? "" : " "
        confirmedTranscript += prefix + text
        let segment = TranscriptSegment(
            startTime: TimeInterval(startSec),
            endTime: TimeInterval(endSec),
            text: text,
            source: source
        )
        segments.append(segment)

        sessionStorage?.appendSegment(SegmentRecord(
            startTime: TimeInterval(startSec),
            endTime: TimeInterval(endSec),
            text: text,
            speaker: nil,
            source: source
        ))

        let tag = source == .mixed ? "" : " [\(source.rawValue)]"
        print("[STT ✓]\(tag) \(text)")
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

    /// Tokenize vocabulary terms into Whisper prompt tokens for biasing.
    /// Returns nil if no vocabulary or tokenizer unavailable.
    private func buildWhisperPromptTokens() -> [Int]? {
        guard !vocabularyTerms.isEmpty, let tokenizer = whisperKit?.tokenizer else { return nil }
        // Join terms into a prompt string. Whisper uses the prompt as "previous context"
        // so these terms bias the model toward recognizing them.
        let prompt = vocabularyTerms.prefix(50).joined(separator: ", ")
        let tokens = tokenizer.encode(text: prompt)
        // Limit to prevent eating into the decode budget
        return tokens.isEmpty ? nil : Array(tokens.prefix(200))
    }
}

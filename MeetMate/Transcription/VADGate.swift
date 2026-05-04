import Foundation
import Accelerate

/// Client-side Voice Activity Detection gate.
///
/// Prevents silence from being streamed to Azure Speech (saves cost + bandwidth).
/// Uses RMS energy with a configurable threshold and hangover period.
/// When speech is detected, the gate opens and stays open for `hangoverSec` after
/// the last speech frame — avoids clipping trailing syllables.
///
/// Future: swap RMS for Silero VAD CoreML model for better accuracy.
final class VADGate: @unchecked Sendable {

    /// RMS threshold below which audio is considered silence.
    var threshold: Float = 0.008

    /// Seconds to keep the gate open after last speech detection.
    var hangoverSec: Float = 0.8

    /// Minimum consecutive speech frames to open the gate (debounce).
    var minSpeechFrames: Int = 2

    private let sampleRate: Float = 16_000

    /// Samples per analysis frame (20ms at 16kHz = 320 samples).
    private let frameSamples: Int = 320

    private var consecutiveSpeechFrames: Int = 0
    private var lastSpeechTime: Float = 0
    private var currentTimeSec: Float = 0
    private var gateOpen = false

    /// Total seconds of audio that passed the gate (sent to cloud).
    private(set) var passedAudioSec: Float = 0

    /// Total seconds of audio received (before gating).
    private(set) var totalAudioSec: Float = 0

    /// Savings ratio: (total - passed) / total
    var savingsRatio: Float {
        guard totalAudioSec > 0 else { return 0 }
        return (totalAudioSec - passedAudioSec) / totalAudioSec
    }

    /// Process audio samples through the VAD gate.
    /// Returns non-nil when audio should be forwarded to cloud STT.
    func process(_ samples: [Float]) -> [Float]? {
        guard !samples.isEmpty else { return nil }

        let durationSec = Float(samples.count) / sampleRate
        totalAudioSec += durationSec

        let rms = computeRMS(samples)
        let isSpeech = rms >= threshold

        if isSpeech {
            consecutiveSpeechFrames += 1
            lastSpeechTime = currentTimeSec + durationSec
        } else {
            consecutiveSpeechFrames = 0
        }

        currentTimeSec += durationSec

        // Open gate on sustained speech
        if !gateOpen && consecutiveSpeechFrames >= minSpeechFrames {
            gateOpen = true
        }

        // Close gate after hangover expires
        if gateOpen && !isSpeech && (currentTimeSec - lastSpeechTime) > hangoverSec {
            gateOpen = false
        }

        if gateOpen {
            passedAudioSec += durationSec
            return samples
        }

        return nil
    }

    /// Reset state (call on new meeting start).
    func reset() {
        consecutiveSpeechFrames = 0
        lastSpeechTime = 0
        currentTimeSec = 0
        gateOpen = false
        passedAudioSec = 0
        totalAudioSec = 0
    }

    // MARK: - RMS

    private func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(samples.count))
        return sqrtf(meanSquare)
    }
}

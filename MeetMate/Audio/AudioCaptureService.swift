import Foundation
import Combine
import AVFoundation

@MainActor
final class AudioCaptureService: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var levels: Float = 0

    private let micCapture = MicrophoneCapture()
    #if os(macOS)
    private let systemAudioCapture = SystemAudioCapture()
    #endif

    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onMicBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onSystemBuffer: ((AVAudioPCMBuffer) -> Void)?

    func start() async throws {
        var micStarted = false
        do {
            try await micCapture.start { [weak self] buffer in
                self?.onAudioBuffer?(buffer)
                self?.onMicBuffer?(buffer)
            }
            micStarted = true

            #if os(macOS)
            try await systemAudioCapture.start { [weak self] buffer in
                self?.onAudioBuffer?(buffer)
                self?.onSystemBuffer?(buffer)
            }
            #endif

            isRecording = true
        } catch {
            if micStarted { micCapture.stop() }
            throw error
        }
    }

    func stop() {
        micCapture.stop()
        #if os(macOS)
        systemAudioCapture.stop()
        #endif
        isRecording = false
    }
}

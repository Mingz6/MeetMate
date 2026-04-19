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

    func start() async throws {
        try await micCapture.start { [weak self] buffer in
            self?.onAudioBuffer?(buffer)
        }

        #if os(macOS)
        try await systemAudioCapture.start { [weak self] buffer in
            self?.onAudioBuffer?(buffer)
        }
        #endif

        isRecording = true
    }

    func stop() {
        micCapture.stop()
        #if os(macOS)
        systemAudioCapture.stop()
        #endif
        isRecording = false
    }
}

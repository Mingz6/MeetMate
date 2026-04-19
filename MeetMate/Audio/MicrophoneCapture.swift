import Foundation
import AVFoundation

final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private var bufferHandler: ((AVAudioPCMBuffer) -> Void)?
    private var bufferCount = 0
    private var tapInstalled = false

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        // Idempotent: if already running, swap the handler and bail.
        if engine.isRunning {
            print("[Mic] start called while running — replacing handler only")
            self.bufferHandler = onBuffer
            return
        }
        self.bufferHandler = onBuffer

        #if os(macOS)
        print("[Mic] requesting mic permission…")
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        print("[Mic] permission granted:", granted)
        guard granted else {
            throw NSError(domain: "MeetMate", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"])
        }
        #endif

        #if os(iOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        let granted = await AVAudioApplication.requestRecordPermission()
        print("[Mic] iOS permission granted:", granted)
        guard granted else {
            throw NSError(domain: "MeetMate", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"])
        }
        #endif

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        print("[Mic] input format: \(format.sampleRate)Hz, \(format.channelCount)ch")

        // Defensively remove any stale tap before installing.
        if tapInstalled {
            input.removeTap(onBus: 0)
            tapInstalled = false
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.bufferCount += 1
            self.bufferHandler?(buffer)
        }
        tapInstalled = true

        engine.prepare()
        try engine.start()
        print("[Mic] engine started")
    }

    func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        print("[Mic] stopped after \(bufferCount) buffers")
        bufferCount = 0
    }
}

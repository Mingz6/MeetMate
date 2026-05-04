#if os(macOS)
import Foundation
import Combine
import ScreenCaptureKit
import CoreImage
import AppKit

/// Captures screen frames at a configurable interval using ScreenCaptureKit.
/// Frames are delivered as JPEG Data to the `onFrame` callback.
/// Designed to run alongside SystemAudioCapture (separate SCStream instance).
@MainActor
final class FrameCaptureService: ObservableObject {
    @Published private(set) var isCapturing = false
    @Published var captureInterval: TimeInterval = 5.0
    @Published var isEnabled = false

    var onFrame: ((CapturedFrame) -> Void)?

    private var captureImpl: FrameCaptureImpl?
    private var meetingStartTime: Date?

    struct CapturedFrame: Sendable {
        let jpeg: Data
        let timestamp: TimeInterval // seconds since meeting start
        let width: Int
        let height: Int
    }

    func start(meetingStart: Date) async throws {
        guard isEnabled else { return }
        guard !isCapturing else { return }

        meetingStartTime = meetingStart
        let impl = FrameCaptureImpl(
            interval: captureInterval,
            meetingStart: meetingStart,
            onFrame: { [weak self] frame in
                Task { @MainActor [weak self] in
                    self?.onFrame?(frame)
                }
            }
        )
        try await impl.start()
        captureImpl = impl
        isCapturing = true
        print("[FrameCapture] started at \(captureInterval)s interval")
    }

    func stop() {
        captureImpl?.stop()
        captureImpl = nil
        isCapturing = false
        meetingStartTime = nil
        print("[FrameCapture] stopped")
    }
}

/// Non-isolated implementation that handles SCStream callbacks.
private final class FrameCaptureImpl: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    private var stream: SCStream?
    private let interval: TimeInterval
    private let meetingStart: Date
    private let onFrame: @Sendable (FrameCaptureService.CapturedFrame) -> Void
    private var lastCaptureTime: Date = .distantPast
    private let jpegQuality: CGFloat = 0.6
    private let maxDimension: CGFloat = 1280

    init(interval: TimeInterval, meetingStart: Date, onFrame: @escaping @Sendable (FrameCaptureService.CapturedFrame) -> Void) {
        self.interval = interval
        self.meetingStart = meetingStart
        self.onFrame = onFrame
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw NSError(domain: "MeetMate", code: 2, userInfo: [NSLocalizedDescriptionKey: "No display for frame capture"])
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = false

        // Scale down to save memory + disk. Keep aspect ratio via display bounds.
        let scale = min(maxDimension / CGFloat(display.width), maxDimension / CGFloat(display.height), 1.0)
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)

        // Frame rate: 1 fps is the minimum SCStream supports. We throttle further in the callback.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .utility))
        try await s.startCapture()
        stream = s
    }

    func stop() {
        let captured = stream
        stream = nil
        guard let captured else { return }
        Task {
            try? await captured.stopCapture()
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // Throttle to configured interval
        let now = Date()
        guard now.timeIntervalSince(lastCaptureTime) >= interval else { return }
        lastCaptureTime = now

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext()

        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality]) else { return }

        let timestamp = now.timeIntervalSince(meetingStart)
        let frame = FrameCaptureService.CapturedFrame(
            jpeg: jpeg,
            timestamp: timestamp,
            width: cgImage.width,
            height: cgImage.height
        )
        onFrame(frame)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[FrameCapture] stream stopped with error: \(error)")
    }
}
#endif

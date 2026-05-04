#if os(macOS)
import Foundation
import Combine
import AVFoundation
import CoreImage
import AppKit

/// Captures webcam frames at a configurable interval using AVCaptureSession.
/// Frames are delivered as JPEG Data to the `onFrame` callback.
@MainActor
final class WebcamCaptureService: ObservableObject {
    @Published private(set) var isCapturing = false
    @Published var captureInterval: TimeInterval = 5.0
    @Published var isEnabled = false

    var onFrame: ((CapturedFrame) -> Void)?

    private var captureImpl: WebcamCaptureImpl?
    private var meetingStartTime: Date?

    struct CapturedFrame: Sendable {
        let jpeg: Data
        let timestamp: TimeInterval // seconds since meeting start
        let width: Int
        let height: Int
    }

    func start(meetingStart: Date) throws {
        guard isEnabled else { return }
        guard !isCapturing else { return }

        meetingStartTime = meetingStart
        let impl = WebcamCaptureImpl(
            interval: captureInterval,
            meetingStart: meetingStart,
            onFrame: { [weak self] frame in
                Task { @MainActor [weak self] in
                    self?.onFrame?(frame)
                }
            }
        )
        try impl.start()
        captureImpl = impl
        isCapturing = true
        print("[WebcamCapture] started at \(captureInterval)s interval")
    }

    func stop() {
        captureImpl?.stop()
        captureImpl = nil
        isCapturing = false
        meetingStartTime = nil
        print("[WebcamCapture] stopped")
    }
}

/// Non-isolated implementation using AVCaptureSession.
private final class WebcamCaptureImpl: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private var session: AVCaptureSession?
    private let interval: TimeInterval
    private let meetingStart: Date
    private let onFrame: @Sendable (WebcamCaptureService.CapturedFrame) -> Void
    private var lastCaptureTime: Date = .distantPast
    private let jpegQuality: CGFloat = 0.6
    private let ciContext = CIContext()
    private let outputQueue = DispatchQueue(label: "dev.mingz.MeetMate.webcam", qos: .utility)

    init(interval: TimeInterval, meetingStart: Date, onFrame: @escaping @Sendable (WebcamCaptureService.CapturedFrame) -> Void) {
        self.interval = interval
        self.meetingStart = meetingStart
        self.onFrame = onFrame
        super.init()
    }

    func start() throws {
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw NSError(domain: "MeetMate", code: 3, userInfo: [NSLocalizedDescriptionKey: "No webcam available"])
        }

        let session = AVCaptureSession()
        session.sessionPreset = .medium

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw NSError(domain: "MeetMate", code: 4, userInfo: [NSLocalizedDescriptionKey: "Cannot add webcam input"])
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(output) else {
            throw NSError(domain: "MeetMate", code: 5, userInfo: [NSLocalizedDescriptionKey: "Cannot add webcam output"])
        }
        session.addOutput(output)

        session.startRunning()
        self.session = session
    }

    func stop() {
        session?.stopRunning()
        session = nil
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastCaptureTime) >= interval else { return }
        lastCaptureTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard let cgImage = ciContext.createCGImage(ciImage, from: CGRect(x: 0, y: 0, width: width, height: height)) else { return }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality]) else { return }

        let timestamp = now.timeIntervalSince(meetingStart)
        let frame = WebcamCaptureService.CapturedFrame(
            jpeg: jpeg,
            timestamp: timestamp,
            width: width,
            height: height
        )
        onFrame(frame)
    }
}
#endif

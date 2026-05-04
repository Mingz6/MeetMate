import Foundation
import AVFoundation

/// Handles all file I/O for a single meeting session.
///
/// Creates a folder at `~/Documents/MeetMate/Sessions/{YYYY-MM-DD-HHmm}/` and writes:
/// - `mic.m4a` / `system.m4a` — incremental audio capture
/// - `transcript.jsonl` — one JSON line per confirmed segment
/// - `polished.md` — append-only polished paragraphs
/// - `cheatsheet.md` — latest snapshot
///
/// All writes are synchronous on a serial queue (cheap I/O, never blocks the main thread).
/// Designed to survive `kill -9` — every write flushes immediately.
final class SessionStorage: Sendable {

    let sessionFolder: URL

    private let fileQueue = DispatchQueue(label: "dev.mingz.MeetMate.SessionStorage", qos: .utility)
    private let micWriter: AudioFileWriter
    private let systemWriter: AudioFileWriter?

    /// Relative path from Documents root, e.g. "MeetMate/Sessions/2026-05-03-1430"
    let relativePath: String

    init(startedAt: Date, isSystemAudioAvailable: Bool) throws {
        let folderName = Self.folderName(from: startedAt)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let root = docs.appendingPathComponent("MeetMate/Sessions", isDirectory: true)
        let folder = root.appendingPathComponent(folderName, isDirectory: true)

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        self.sessionFolder = folder
        self.relativePath = "MeetMate/Sessions/\(folderName)"

        self.micWriter = try AudioFileWriter(url: folder.appendingPathComponent("mic.m4a"))

        if isSystemAudioAvailable {
            self.systemWriter = try AudioFileWriter(url: folder.appendingPathComponent("system.m4a"))
        } else {
            self.systemWriter = nil
        }

        print("[Storage] session folder: \(folder.path)")
    }

    static func folderName(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    static func sessionsRoot() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("MeetMate/Sessions", isDirectory: true)
    }

    // MARK: - Audio

    func writeMicBuffer(_ buffer: AVAudioPCMBuffer) {
        micWriter.write(buffer)
    }

    func writeSystemBuffer(_ buffer: AVAudioPCMBuffer) {
        systemWriter?.write(buffer)
    }

    func finalizeAudio() {
        micWriter.close()
        systemWriter?.close()
    }

    /// URL to mic.m4a for playback
    var micAudioURL: URL { sessionFolder.appendingPathComponent("mic.m4a") }

    // MARK: - Transcript segments

    func appendSegment(_ segment: SegmentRecord) {
        guard let data = try? JSONEncoder().encode(segment),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        fileQueue.async { [sessionFolder] in
            let url = sessionFolder.appendingPathComponent("transcript.jsonl")
            Self.appendString(line, to: url)
        }
    }

    // MARK: - Polished paragraphs (append-only JSONL)

    func appendParagraph(_ paragraph: PolishedParagraph) {
        guard let data = try? JSONEncoder().encode(paragraph),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        fileQueue.async { [sessionFolder] in
            let url = sessionFolder.appendingPathComponent("paragraphs.jsonl")
            Self.appendString(line, to: url)
        }
    }

    /// Load all versions of a specific paragraph from paragraphs.jsonl (sync read for UI popover).
    func loadVersionHistory(forId paragraphId: String) -> [PolishedParagraph] {
        let url = sessionFolder.appendingPathComponent("paragraphs.jsonl")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return content.components(separatedBy: "\n")
            .compactMap { line -> PolishedParagraph? in
                guard !line.isEmpty, let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(PolishedParagraph.self, from: data)
            }
            .filter { $0.id == paragraphId }
            .sorted { $0.version < $1.version }
    }

    // MARK: - Polished transcript (human-readable markdown)

    func writePolished(paragraphs: [String], draft: String) {
        fileQueue.async { [sessionFolder] in
            let url = sessionFolder.appendingPathComponent("polished.md")
            var content = paragraphs.enumerated().map { i, p in
                "\(i + 1). \(p)"
            }.joined(separator: "\n\n")
            if !draft.isEmpty {
                content += "\n\n---\n*Draft:* \(draft)"
            }
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Cheatsheet

    func writeCheatsheet(topic: String, keyPoints: [String], questions: [String], actions: [String]) {
        fileQueue.async { [sessionFolder] in
            let url = sessionFolder.appendingPathComponent("cheatsheet.md")
            var lines: [String] = []
            lines.append("# Cheatsheet")
            lines.append("")
            if !topic.isEmpty {
                lines.append("## Topic")
                lines.append(topic)
                lines.append("")
            }
            if !keyPoints.isEmpty {
                lines.append("## Key Points")
                keyPoints.forEach { lines.append("- \($0)") }
                lines.append("")
            }
            if !questions.isEmpty {
                lines.append("## Open Questions")
                questions.forEach { lines.append("- \($0)") }
                lines.append("")
            }
            if !actions.isEmpty {
                lines.append("## Action Items")
                actions.forEach { lines.append("- \($0)") }
            }
            let content = lines.joined(separator: "\n")
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Context

    func writeContext(_ context: String) {
        fileQueue.async { [sessionFolder] in
            let url = sessionFolder.appendingPathComponent("context.md")
            try? context.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Frames (video capture)

    /// Maximum number of frames to keep per session. Oldest are pruned.
    private static let maxFrames = 720 // ~1 hour at 5s interval

    /// Save a captured frame as JPEG. Returns the file URL.
    @discardableResult
    func writeFrame(jpeg: Data, timestamp: TimeInterval) -> URL? {
        let framesDir = sessionFolder.appendingPathComponent("frames", isDirectory: true)
        let filename = String(format: "frame_%06.1f.jpg", timestamp)
        let url = framesDir.appendingPathComponent(filename)

        fileQueue.async {
            try? FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
            try? jpeg.write(to: url)
        }
        return url
    }

    /// Prune old frames beyond the cap. Call periodically.
    func pruneFrames() {
        fileQueue.async { [sessionFolder] in
            let framesDir = sessionFolder.appendingPathComponent("frames", isDirectory: true)
            guard let files = try? FileManager.default.contentsOfDirectory(at: framesDir, includingPropertiesForKeys: [.creationDateKey])
                .filter({ $0.pathExtension == "jpg" })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) else { return }

            let excess = files.count - Self.maxFrames
            guard excess > 0 else { return }
            for file in files.prefix(excess) {
                try? FileManager.default.removeItem(at: file)
            }
            print("[Storage] pruned \(excess) old frame(s)")
        }
    }

    /// URL of the frames directory.
    var framesDirectory: URL { sessionFolder.appendingPathComponent("frames", isDirectory: true) }

    /// Load the most recent frame as Data (for vision LLM calls).
    func latestFrame() -> (data: Data, timestamp: TimeInterval)? {
        let framesDir = sessionFolder.appendingPathComponent("frames", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: framesDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "jpg" })
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent }),
              let latest = files.first,
              let data = try? Data(contentsOf: latest) else { return nil }

        // Parse timestamp from filename: frame_000123.4.jpg
        let name = latest.deletingPathExtension().lastPathComponent
        let numStr = name.replacingOccurrences(of: "frame_", with: "")
        let timestamp = TimeInterval(numStr) ?? 0
        return (data, timestamp)
    }

    // MARK: - Delete

    func deleteSessionFolder() throws {
        try FileManager.default.removeItem(at: sessionFolder)
        print("[Storage] deleted \(sessionFolder.path)")
    }

    // MARK: - Helpers

    private static func appendString(_ string: String, to url: URL) {
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            if let data = string.data(using: .utf8) {
                handle.write(data)
            }
            handle.closeFile()
        } else {
            try? string.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Segment record for JSONL serialization

struct SegmentRecord: Codable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let speaker: String?
    let source: AudioSource?
}

// MARK: - Audio file writer (M4A/AAC incremental)

/// Wraps AVAudioFile for incremental AAC writes. Thread-safe via internal serial queue.
/// Caches the format converter to avoid per-buffer allocation overhead (~12 buffers/sec from mic).
final class AudioFileWriter: Sendable {
    private let queue = DispatchQueue(label: "dev.mingz.MeetMate.AudioFileWriter", qos: .utility)
    private nonisolated(unsafe) var audioFile: AVAudioFile?
    private nonisolated(unsafe) var cachedConverter: AVAudioConverter?
    private nonisolated(unsafe) var cachedInputFormat: AVAudioFormat?

    init(url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        self.audioFile = try AVAudioFile(forWriting: url, settings: settings)
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self, let file = self.audioFile else { return }

            if buffer.format == file.processingFormat {
                do {
                    try file.write(from: buffer)
                } catch {
                    print("[AudioFileWriter] direct write failed: \(error)")
                }
            } else if let converted = self.convertCached(buffer, to: file.processingFormat) {
                do {
                    try file.write(from: converted)
                } catch {
                    print("[AudioFileWriter] converted write failed: \(error)")
                }
            } else {
                print("[AudioFileWriter] conversion failed: \(buffer.format) → \(file.processingFormat)")
            }
        }
    }

    func close() {
        queue.sync { [weak self] in
            self?.audioFile = nil
            self?.cachedConverter = nil
            self?.cachedInputFormat = nil
        }
    }

    /// Reuses the converter if the input format hasn't changed (it shouldn't within a session).
    private func convertCached(_ buffer: AVAudioPCMBuffer, to outputFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let converter: AVAudioConverter
        if let cached = cachedConverter, cachedInputFormat == buffer.format {
            converter = cached
        } else {
            guard let newConverter = AVAudioConverter(from: buffer.format, to: outputFormat) else {
                print("[AudioFileWriter] can't create converter: \(buffer.format) → \(outputFormat)")
                return nil
            }
            cachedConverter = newConverter
            cachedInputFormat = buffer.format
            converter = newConverter
        }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        var error: NSError?
        var consumed = false
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        if let error {
            print("[AudioFileWriter] convert error: \(error)")
            return nil
        }
        return output
    }
}

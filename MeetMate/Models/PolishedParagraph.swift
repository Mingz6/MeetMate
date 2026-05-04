import Foundation

/// A polished paragraph with stable ID, timestamps, and version tracking.
///
/// IDs are assigned by Swift (not the LLM) — monotonic per session, never reused.
/// Format: `p_{6-digit zero-padded}`, e.g. "p_000001".
/// Version starts at 1 and increments if §6 re-polish revises it.
struct PolishedParagraph: Codable, Identifiable, Sendable {
    let id: String        // e.g. "p_000001"
    let text: String
    let startSec: Float
    let endSec: Float
    let version: Int
    let source: AudioSource?

    /// Format timestamp as [mm:ss]
    var timestampLabel: String {
        let totalSec = Int(startSec)
        let min = totalSec / 60
        let sec = totalSec % 60
        return String(format: "[%02d:%02d]", min, sec)
    }

    /// Human-readable source label: "me" for mic, "remote" for system
    var sourceLabel: String? {
        switch source {
        case .mic: return "me"
        case .system: return "remote"
        default: return nil
        }
    }
}

/// A proposed revision to one or more existing paragraphs.
/// The LLM suggests merging/replacing `replaceIds` with `newText`.
/// User must accept or reject before it lands in the paragraph list.
struct ParagraphRevision: Identifiable, Sendable {
    let id: UUID = UUID()
    let replaceIds: [String]    // paragraph IDs to replace
    let newText: String         // revised text
    let reason: String          // LLM explanation
    let timestamp: Date = .now
}

/// Generator for stable paragraph IDs. Monotonic per session, never reused.
@MainActor
final class ParagraphIDGenerator {
    private var counter: Int = 0

    func next() -> String {
        counter += 1
        return String(format: "p_%06d", counter)
    }

    func reset() {
        counter = 0
    }
}

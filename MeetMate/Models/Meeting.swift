import Foundation
import SwiftData

@Model
final class Meeting {
    var id: UUID
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var audioFilePath: String?
    var summary: String?

    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.meeting)
    var segments: [TranscriptSegment] = []

    init(title: String = "Untitled meeting", startedAt: Date = .now) {
        self.id = UUID()
        self.title = title
        self.startedAt = startedAt
    }
}

@Model
final class TranscriptSegment {
    var id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var speaker: String?
    var meeting: Meeting?

    init(startTime: TimeInterval, endTime: TimeInterval, text: String, speaker: String? = nil) {
        self.id = UUID()
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.speaker = speaker
    }
}

struct Cheatsheet {
    var currentTopic: String = ""
    var keyPoints: [String] = []
    var openQuestions: [String] = []
    var actionItems: [String] = []
    var lastUpdated: Date = .now
}

struct ReplySuggestion: Identifiable {
    let id = UUID()
    let triggerQuestion: String
    let suggestedReply: String
    let createdAt: Date = .now
}

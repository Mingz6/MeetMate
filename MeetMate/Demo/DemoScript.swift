import Foundation

/// Launch flag for demo mode: `MeetMate.app/Contents/MacOS/MeetMate --demo`.
///
/// Demo mode replays a scripted, fictional meeting through the real pane views.
/// It touches no microphone, Keychain, network or model download, so it runs on a fresh clone with no setup.
///
/// The unit-test host app also starts in demo mode. Otherwise every `xcodebuild test` would launch the
/// real window, start downloading the local models and open the SwiftData store on disk.
enum DemoMode {
    static var isActive: Bool { CommandLine.arguments.contains("--demo") || isTestHost }

    static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Seconds between script steps. Override with `-demoInterval 0.5`.
    static var stepInterval: Double {
        let value = UserDefaults.standard.double(forKey: "demoInterval")
        return value > 0 ? value : 1.6
    }

    /// Seconds before the first step. Override with `-demoStartDelay 3`.
    static var startDelay: Double {
        let value = UserDefaults.standard.double(forKey: "demoStartDelay")
        return value > 0 ? value : stepInterval
    }
}

/// Everything the panes show at one moment of the scripted meeting.
struct DemoState {
    var isRecording = true
    var confirmed = ""
    var interim = ""
    var paragraphs: [PolishedParagraph] = []
    var draft = ""
    var sheet = Cheatsheet()
    var suggestion: ReplySuggestion?
    var revisions: [ParagraphRevision] = []
    var usage = SessionTokenUsage()
    var vadSavings: Float = 0
}

/// A made-up product-launch sync. Every name, date and product here is fictional.
enum DemoScript {
    typealias Step = (inout DemoState) -> Void

    /// Paragraph id used by the dark-mode revision at the end of the script.
    static let revisedParagraphID = "p_000006"

    static var stepCount: Int { steps.count }

    /// State after applying the first `count` steps.
    static func state(afterSteps count: Int) -> DemoState {
        var state = DemoState()
        for step in steps.prefix(count) { step(&state) }
        return state
    }

    static func apply(stepAt index: Int, to state: inout DemoState) {
        guard steps.indices.contains(index) else { return }
        steps[index](&state)
    }

    private static func paragraph(_ n: Int, _ text: String, from start: Float, to end: Float, source: AudioSource, version: Int = 1) -> PolishedParagraph {
        PolishedParagraph(id: String(format: "p_%06d", n), text: text, startSec: start, endSec: end, version: version, source: source)
    }

    private static let steps: [Step] = [
        // 1. Audio starts flowing.
        { s in
            s.interim = "okay let's get started so the main thing"
            s.vadSavings = 0.31
        },
        // 2. First phrase is final. The speech model hears "fern would"; the polish pass will fix it.
        { s in
            s.confirmed = "Okay, let's get started. So the main thing today is the fern would launch date."
            s.interim = ""
            s.draft = "Let's get started. The main thing today is the"
            s.sheet.currentTopic = "Fernwood launch date"
            s.vadSavings = 0.38
        },
        // 3. First polished paragraph lands, with a timestamp and the remote speaker tag.
        { s in
            s.paragraphs.append(paragraph(1, "Let's get started. The main thing today is the Fernwood launch date.", from: 4, to: 11, source: .system))
            s.draft = ""
            s.interim = "Marcus says the build is basically done but"
            s.usage.add(TokenUsage(promptTokens: 1_840, completionTokens: 120))
        },
        // 4. Live text keeps streaming; the cheatsheet picks up the first key points.
        { s in
            s.confirmed += " Marcus says the build is basically done but the push notification service is still flaky on android."
            s.interim = ""
            s.sheet.keyPoints = ["Build is feature-complete", "Android push notifications still flaky"]
            s.vadSavings = 0.42
        },
        // 5. Second paragraph.
        { s in
            s.paragraphs.append(paragraph(2, "Marcus says the build is basically done, but the push notification service is still flaky on Android.", from: 19, to: 27, source: .system))
            s.interim = "I think we need two more days"
            s.usage.add(TokenUsage(promptTokens: 2_460, completionTokens: 210))
        },
        // 6. The user speaks (mic source). The vision pass notes what is on the shared slide.
        { s in
            s.confirmed += " I think we need two more days to fix that, maybe three if the store review is slow."
            s.interim = ""
            s.paragraphs.append(paragraph(3, "I think we need two more days to fix that, maybe three if store review is slow.", from: 41, to: 48, source: .mic))
            s.sheet.keyPoints.append("Fix needs 2 to 3 days")
            s.sheet.openQuestions = ["Will app store review add delay?"]
            s.sheet.screenContext = "Slide \"Fernwood launch checklist\" is shared. The Android push item is highlighted red."
            s.usage.add(TokenUsage(promptTokens: 3_050, completionTokens: 260))
        },
        // 7. Someone says the user's name. A reply suggestion appears.
        { s in
            let question = "Alex, can you confirm that date works for support?"
            s.confirmed += " Right, so if we ship December fifth we get a week of buffer before the holidays. \(question)"
            s.paragraphs.append(paragraph(4, "If we ship December 5th, we get a week of buffer before the holidays. \(question)", from: 62, to: 72, source: .system))
            s.suggestion = ReplySuggestion(
                triggerQuestion: question,
                suggestedReply: "Yes, December 5th works for support. We'll have the help articles ready by the 28th."
            )
            s.sheet.currentTopic = "Ship date and support readiness"
            s.sheet.keyPoints.append("Proposed ship date: December 5")
            s.sheet.actionItems = ["Alex: confirm December 5 with support"]
            s.usage.add(TokenUsage(promptTokens: 3_620, completionTokens: 330))
            s.vadSavings = 0.44
        },
        // 8. The user answers; the suggestion clears.
        { s in
            s.confirmed += " Yes, December fifth works for support. We'll have the help articles ready by the twenty eighth."
            s.paragraphs.append(paragraph(5, "Yes, December 5th works for support. We'll have the help articles ready by the 28th.", from: 85, to: 93, source: .mic))
            s.suggestion = nil
            s.sheet.actionItems = ["Marcus: fix Android push before the release build", "Alex: help articles ready by the 28th"]
            s.usage.add(TokenUsage(promptTokens: 4_100, completionTokens: 390))
        },
        // 9. A speaker changes their mind mid-sentence.
        { s in
            s.confirmed += " One more thing. We said we'd cut the dark mode toggle from one point oh. Actually no, keep it, we'll just ship it in one point one."
            s.paragraphs.append(paragraph(6, "We said we'd cut the dark mode toggle from 1.0. Actually no, keep it, we'll just ship it in 1.1.", from: 108, to: 118, source: .system))
            s.sheet.currentTopic = "Scope for 1.0"
            s.usage.add(TokenUsage(promptTokens: 4_700, completionTokens: 450))
        },
        // 10. Re-polish proposes a cleaner version. The old text is struck through until the user accepts.
        { s in
            s.revisions = [ParagraphRevision(
                replaceIds: [revisedParagraphID],
                newText: "Dark mode toggle moves from 1.0 to 1.1 so it won't block the launch.",
                reason: "Speaker corrected themselves."
            )]
            s.usage.add(TokenUsage(promptTokens: 5_200, completionTokens: 520))
        },
        // 11. Accepted: same paragraph id, version 2.
        { s in
            guard let revision = s.revisions.first,
                  let index = s.paragraphs.firstIndex(where: { $0.id == revision.replaceIds.first }) else { return }
            let old = s.paragraphs[index]
            s.paragraphs[index] = PolishedParagraph(
                id: old.id, text: revision.newText,
                startSec: old.startSec, endSec: old.endSec,
                version: old.version + 1, source: old.source
            )
            s.revisions = []
            s.sheet.keyPoints.append("Dark mode toggle moves to 1.1")
        },
    ]
}

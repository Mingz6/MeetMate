//
//  MeetMateTests.swift
//  MeetMateTests
//
//  Unit tests for the pure logic: voice-activity gate, vocabulary extraction,
//  paragraph contract, task routing, token cost, and the demo script.
//

import Foundation
import Testing
@testable import MeetMate

@MainActor
struct VADGateTests {

    /// 20 ms of 16 kHz audio at a constant amplitude (RMS equals the amplitude).
    private func frame(amplitude: Float, samples: Int = 320) -> [Float] {
        [Float](repeating: amplitude, count: samples)
    }

    @Test func silenceNeverPassesTheGate() {
        let gate = VADGate()
        for _ in 0..<50 {
            #expect(gate.process(frame(amplitude: 0.0001)) == nil)
        }
        #expect(gate.passedAudioSec == 0)
        #expect(gate.savingsRatio == 1)
    }

    @Test func gateNeedsTwoSpeechFramesToOpen() {
        let gate = VADGate()
        #expect(gate.process(frame(amplitude: 0.1)) == nil)
        #expect(gate.process(frame(amplitude: 0.1)) != nil)
    }

    @Test func gateStaysOpenThroughHangoverThenCloses() {
        let gate = VADGate()
        _ = gate.process(frame(amplitude: 0.1))
        _ = gate.process(frame(amplitude: 0.1))
        // 0.8 s hangover: 20 ms silent frames stay open at first...
        #expect(gate.process(frame(amplitude: 0)) != nil)
        // ...and the gate is shut after a full second of silence.
        var lastResult: [Float]? = []
        for _ in 0..<60 { lastResult = gate.process(frame(amplitude: 0)) }
        #expect(lastResult == nil)
    }

    @Test func savingsRatioTracksDroppedAudio() {
        let gate = VADGate()
        for _ in 0..<10 { _ = gate.process(frame(amplitude: 0)) }   // dropped
        for _ in 0..<10 { _ = gate.process(frame(amplitude: 0.1)) } // mostly passed
        #expect(gate.totalAudioSec > gate.passedAudioSec)
        #expect(gate.savingsRatio > 0 && gate.savingsRatio < 1)
        gate.reset()
        #expect(gate.totalAudioSec == 0)
        #expect(gate.savingsRatio == 0)
    }
}

struct VocabularyExtractorTests {

    @Test func emptyTextGivesNoTerms() {
        #expect(VocabularyExtractor.extract(from: "").isEmpty)
    }

    @Test func picksUpAcronymsAndProperNouns() {
        let text = "We will compare KV cache sizes. Later we hear from Sarah Whitfield about the NASA results."
        let terms = Set(VocabularyExtractor.extract(from: text))
        #expect(terms.contains("NASA"))
        #expect(terms.contains("Sarah Whitfield"))
    }

    @Test func skipsCommonUppercaseWords() {
        let terms = VocabularyExtractor.extract(from: "OK so IT is fine. I will go TO the shop.")
        #expect(!terms.contains("OK"))
        #expect(!terms.contains("IT"))
        #expect(!terms.contains("TO"))
    }

    @Test func hyphenatedTermsNeedFiveCharacters() {
        let terms = Set(VocabularyExtractor.extract(from: "self-attention helps, a-b does not."))
        #expect(terms.contains("self-attention"))
        #expect(!terms.contains("a-b"))
    }

    @Test func mergeKeepsUserTermsAndOrdersLongestFirst() {
        let merged = VocabularyExtractor.merge(extracted: ["GPU", "Fernwood Labs"], userEdited: ["Fernwood Labs", "RAG"])
        #expect(Set(merged) == ["GPU", "Fernwood Labs", "RAG"])
        #expect(merged.first == "Fernwood Labs")
    }

    @Test func mergeCapsAtTwoHundredPhrases() {
        let many = (0..<500).map { "term\($0)" }
        #expect(VocabularyExtractor.merge(extracted: many, userEdited: []).count == 200)
    }
}

@MainActor
struct ParagraphContractTests {

    @Test func idsAreMonotonicAndZeroPadded() {
        let generator = ParagraphIDGenerator()
        #expect(generator.next() == "p_000001")
        #expect(generator.next() == "p_000002")
        generator.reset()
        #expect(generator.next() == "p_000001")
    }

    @Test func timestampLabelIsMinutesAndSeconds() {
        let p = PolishedParagraph(id: "p_000001", text: "x", startSec: 125.9, endSec: 130, version: 1, source: .mic)
        #expect(p.timestampLabel == "[02:05]")
    }

    @Test func speakerLabelPrefersDiarizationOverSource() {
        let remote = PolishedParagraph(id: "p_000001", text: "x", startSec: 0, endSec: 1, version: 1, source: .system)
        let me = PolishedParagraph(id: "p_000002", text: "x", startSec: 0, endSec: 1, version: 1, source: .mic)
        let diarized = PolishedParagraph(id: "p_000003", text: "x", startSec: 0, endSec: 1, version: 1, source: .system, speakerId: 2)
        #expect(remote.speakerLabel == "remote")
        #expect(me.speakerLabel == "me")
        #expect(diarized.speakerLabel == "Speaker 2")
    }

    @Test func paragraphSurvivesJSONRoundTrip() throws {
        let original = PolishedParagraph(id: "p_000007", text: "Ship it.", startSec: 1.5, endSec: 2.5, version: 3, source: .system, speakerId: 1)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PolishedParagraph.self, from: data)
        #expect(decoded.id == original.id)
        #expect(decoded.version == 3)
        #expect(decoded.source == .system)
        #expect(decoded.speakerId == 1)
    }
}

@MainActor
struct RoutingAndCostTests {

    @Test func highFrequencyTasksPreferTheMiniDeployment() {
        #expect(LLMTask.polish.prefersMini)
        #expect(LLMTask.cheatsheet.prefersMini)
        for task in [LLMTask.reply, .rePolish, .batchPolish, .vision, .general] {
            #expect(!task.prefersMini)
        }
    }

    @Test func sessionUsageAddsUpAndEstimatesCost() {
        var usage = SessionTokenUsage()
        usage.add(TokenUsage(promptTokens: 1_000, completionTokens: 1_000))
        usage.add(TokenUsage(promptTokens: 1_000, completionTokens: 0))
        #expect(usage.totalTokens == 3_000)
        // $0.01 per 1K prompt, $0.03 per 1K completion
        #expect(abs(usage.estimatedCostUSD - 0.05) < 1e-9)
        usage.reset()
        #expect(usage.totalTokens == 0)
    }

    @Test func sessionFolderNameIsSortableTimestamp() {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 5; parts.day = 3; parts.hour = 14; parts.minute = 30
        let date = Calendar.current.date(from: parts)!
        #expect(SessionStorage.folderName(from: date) == "2026-05-03-1430")
    }
}

@MainActor
struct DemoScriptTests {

    @Test func scriptStartsEmptyAndEndsWithAFullMeeting() {
        let start = DemoScript.state(afterSteps: 0)
        #expect(start.paragraphs.isEmpty)
        let end = DemoScript.state(afterSteps: DemoScript.stepCount)
        #expect(end.paragraphs.count == 6)
        #expect(end.usage.totalTokens > 0)
        #expect(!end.sheet.actionItems.isEmpty)
    }

    @Test func paragraphIdsAreUniqueAndTimestampsAscend() {
        let paragraphs = DemoScript.state(afterSteps: DemoScript.stepCount).paragraphs
        #expect(Set(paragraphs.map(\.id)).count == paragraphs.count)
        let starts = paragraphs.map(\.startSec)
        #expect(starts == starts.sorted())
    }

    @Test func revisionTargetsAnExistingParagraphAndBumpsItsVersion() {
        // Step 10 proposes the revision; step 11 accepts it.
        let proposed = DemoScript.state(afterSteps: DemoScript.stepCount - 1)
        let revision = try! #require(proposed.revisions.first)
        #expect(proposed.paragraphs.contains { $0.id == revision.replaceIds.first })

        let accepted = DemoScript.state(afterSteps: DemoScript.stepCount)
        #expect(accepted.revisions.isEmpty)
        let revised = try! #require(accepted.paragraphs.first { $0.id == DemoScript.revisedParagraphID })
        #expect(revised.version == 2)
    }

    @Test func nameMentionShowsAReplySuggestionThatLaterClears() {
        let atMention = (0...DemoScript.stepCount).map { DemoScript.state(afterSteps: $0) }.first { $0.suggestion != nil }
        #expect(atMention != nil)
        #expect(DemoScript.state(afterSteps: DemoScript.stepCount).suggestion == nil)
    }

    @Test func testHostStartsInDemoMode() {
        // Keeps `xcodebuild test` from launching the real app (model downloads, on-disk store).
        #expect(DemoMode.isTestHost)
        #expect(DemoMode.isActive)
    }

    @Test func demoContentHasNoPersonalIdentifiers() {
        let end = DemoScript.state(afterSteps: DemoScript.stepCount)
        let text = ([end.confirmed] + end.paragraphs.map(\.text) + end.sheet.keyPoints + end.sheet.actionItems).joined(separator: " ")
        #expect(!text.contains("@"))
        #expect(!text.lowercased().contains("azure"))
    }
}

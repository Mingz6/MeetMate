import SwiftUI
@preconcurrency import AVFoundation
import SwiftData

struct MainView: View {
    @Environment(\.modelContext) private var context
    @StateObject private var audio = AudioCaptureService()
    @StateObject private var transcriber = TranscriptionService()
    @StateObject private var llm = LLMService()
    @StateObject private var cheatsheet: CheatsheetGenerator
    @StateObject private var replier: ReplyGenerator
    @StateObject private var polisher: TranscriptPolisher

    @AppStorage("userName") private var userName: String = "Ming"
    @AppStorage("showLive") private var showLive: Bool = true
    @AppStorage("showPolished") private var showPolished: Bool = true
    @AppStorage("showCheatsheet") private var showCheatsheet: Bool = true
    @State private var currentMeeting: Meeting?

    init() {
        let llmInstance = LLMService()
        _llm = StateObject(wrappedValue: llmInstance)
        _cheatsheet = StateObject(wrappedValue: CheatsheetGenerator(llm: llmInstance))
        _replier = StateObject(wrappedValue: ReplyGenerator(llm: llmInstance))
        _polisher = StateObject(wrappedValue: TranscriptPolisher(llm: llmInstance))
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                if audio.isRecording {
                    Button(action: stopMeeting) {
                        Label("Stop", systemImage: "stop.circle.fill").foregroundStyle(.red)
                    }
                } else {
                    Button(action: startMeeting) {
                        Label("Record", systemImage: "record.circle")
                    }
                }
                Divider().frame(height: 16)
                Toggle(isOn: $showLive) { Label("Live", systemImage: "waveform") }
                Toggle(isOn: $showPolished) { Label("Polished", systemImage: "wand.and.stars") }
                Toggle(isOn: $showCheatsheet) { Label("Topic summary", systemImage: "lightbulb") }
                Spacer()
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal)

            HStack(spacing: 16) {
                if showLive || showPolished {
                    VStack(alignment: .leading, spacing: 8) {
                        transcriptPane
                        HStack(spacing: 8) {
                            Image(systemName: polisher.isPolishing ? "wand.and.stars" : "wand.and.stars.inverse")
                            Text("polished \(polisher.finalizedParagraphs.count) paragraphs · \(polisher.isPolishing ? "updating…" : "idle")")
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                if showCheatsheet {
                    CheatsheetView(
                        sheet: cheatsheet.current,
                        suggestion: replier.pendingSuggestion,
                        onDismissSuggestion: replier.dismiss
                    )
                    .frame(width: 400)
                }
                if !showLive && !showPolished && !showCheatsheet {
                    ContentUnavailableView("Nothing to show", systemImage: "eye.slash", description: Text("Enable a pane above."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding([.horizontal, .bottom])
        }
        .padding(.top, 8)
        .task {
            do {
                try await transcriber.loadModel()
            } catch {
                print("[Whisper] loadModel failed:", error)
            }
            do {
                let override = UserDefaults.standard.string(forKey: "modelChoiceOverride") ?? ""
                let choice = LLMService.ModelChoice(rawValue: override)
                try await llm.load(choice)
            } catch {
                print("[LLM] load failed:", error)
            }
        }
    }

    private func startMeeting() {
        let meeting = Meeting(title: "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))")
        context.insert(meeting)
        currentMeeting = meeting
        transcriber.reset()

        audio.onAudioBuffer = { [weak transcriber] buffer in
            Task { @MainActor in
                transcriber?.ingest(buffer)
            }
        }

        Task {
            do {
                try await audio.start()
            } catch {
                print("[Meeting] audio start failed:", error)
                context.delete(meeting)
                currentMeeting = nil
                return
            }
            cheatsheet.startRolling { transcriber.liveTranscript }
            polisher.start(reading: transcriber)
            replier.startWatching(
                userName: userName,
                transcriptProvider: { transcriber.liveTranscript },
                cheatsheetProvider: { cheatsheet.current }
            )
        }
    }

    private func stopMeeting() {
        audio.stop()
        cheatsheet.stopRolling()
        polisher.stop()
        replier.stopWatching()
        currentMeeting?.endedAt = .now
        // TODO: Phase 1.7 - run final summary, save to ~/code/crna/meetings/
    }

    @ViewBuilder
    private var transcriptPane: some View {
        switch (showLive, showPolished) {
        case (true, false):
            TranscriptView(
                confirmed: transcriber.confirmedTranscript,
                interim: transcriber.unconfirmedText
            )
        case (false, true):
            PolishedTranscriptView(
                finalizedParagraphs: polisher.finalizedParagraphs,
                currentDraft: polisher.currentDraft,
                rawFallback: transcriber.liveTranscript
            )
        case (true, true):
            HStack(alignment: .top, spacing: 12) {
                TranscriptView(
                    confirmed: transcriber.confirmedTranscript,
                    interim: transcriber.unconfirmedText
                )
                .frame(maxWidth: .infinity)
                PolishedTranscriptView(
                    finalizedParagraphs: polisher.finalizedParagraphs,
                    currentDraft: polisher.currentDraft,
                    rawFallback: transcriber.liveTranscript
                )
                .frame(maxWidth: .infinity)
            }
        case (false, false):
            EmptyView()
        }
    }
}

enum TranscriptMode: String, CaseIterable, Identifiable {
    case live, polished, sideBySide
    var id: String { rawValue }
    var label: String {
        switch self {
        case .live: return "Live"
        case .polished: return "Polished"
        case .sideBySide: return "Side by side"
        }
    }
    var icon: String {
        switch self {
        case .live: return "waveform"
        case .polished: return "wand.and.stars"
        case .sideBySide: return "rectangle.split.2x1"
        }
    }
}

private struct ControlPanel: View {
    let isRecording: Bool
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("MeetMate")
                .font(.largeTitle).bold()

            if isRecording {
                Button(action: onStop) {
                    Label("Stop", systemImage: "stop.circle.fill")
                        .foregroundStyle(.red)
                        .font(.title)
                }
            } else {
                Button(action: onStart) {
                    Label("Start meeting", systemImage: "record.circle")
                        .font(.title)
                }
            }

            Spacer()
        }
        .padding()
        .frame(minWidth: 220)
    }
}

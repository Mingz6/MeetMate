#if os(macOS)
import SwiftUI
@preconcurrency import AVFoundation
import SwiftData

struct MainView: View {
    @Environment(\.modelContext) private var context
    @StateObject private var audio = AudioCaptureService()
    @StateObject private var transcriber = TranscriptionService()
    @StateObject private var llm: LLMService
    @StateObject private var cheatsheet: CheatsheetGenerator
    @StateObject private var replier: ReplyGenerator
    @StateObject private var polisher: TranscriptPolisher

    @AppStorage("userName") private var userName: String = "Ming"
    @AppStorage("showLive") private var showLive: Bool = true
    @AppStorage("showPolished") private var showPolished: Bool = true
    @AppStorage("showCheatsheet") private var showCheatsheet: Bool = true
    @State private var currentMeeting: Meeting?
    @State private var startError: String?
    @State private var loadError: String?

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
                    HStack(spacing: 6) {
                        RecordingDot()
                        Button(action: stopMeeting) {
                            Label("Stop", systemImage: "stop.circle.fill").foregroundStyle(.red)
                        }
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
                Button(action: copyTranscript) {
                    Label("Copy transcript", systemImage: "doc.on.doc")
                }
                .disabled(transcriber.confirmedTranscript.isEmpty)
                .help("Copy confirmed transcript to clipboard")
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal)

            if !llm.isLoaded {
                ModelLoadingBanner(progress: llm.loadProgress, modelName: LLMService.recommendedModel().displayName)
                    .padding(.horizontal)
            }

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
        .alert("Couldn’t start recording", isPresented: Binding(get: { startError != nil }, set: { if !$0 { startError = nil } })) {
            Button("OK", role: .cancel) { startError = nil }
        } message: {
            Text(startError ?? "")
        }
        .alert("Model failed to load", isPresented: Binding(get: { loadError != nil }, set: { if !$0 { loadError = nil } })) {
            Button("OK", role: .cancel) { loadError = nil }
        } message: {
            Text(loadError ?? "")
        }
        .task {
            do {
                try await transcriber.loadModel()
            } catch {
                print("[Whisper] loadModel failed:", error)
                loadError = "Whisper: \(error.localizedDescription)"
            }
            do {
                let override = UserDefaults.standard.string(forKey: "modelChoiceOverride") ?? ""
                let choice = LLMService.ModelChoice(rawValue: override)
                try await llm.load(choice)
            } catch {
                print("[LLM] load failed:", error)
                loadError = "LLM: \(error.localizedDescription)"
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
                startError = error.localizedDescription
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
        // TODO: Phase 1.7 — run final summary, save markdown to meetingsArchivePath setting
    }

    #if os(macOS)
    private func copyTranscript() {
        let text = transcriber.confirmedTranscript
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    #else
    private func copyTranscript() {}
    #endif

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

private struct RecordingDot: View {
    @State private var pulse = false
    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 8, height: 8)
            .opacity(pulse ? 1.0 : 0.3)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
            .accessibilityLabel("Recording")
    }
}

private struct ModelLoadingBanner: View {
    let progress: Double
    let modelName: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Loading \(modelName)…").font(.caption).bold()
                if progress > 0 {
                    ProgressView(value: progress)
                        .frame(maxWidth: 240)
                } else {
                    Text("Starting up… first run downloads several GB.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
#endif

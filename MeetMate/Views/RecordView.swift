#if os(iOS)
import SwiftUI
@preconcurrency import AVFoundation
import SwiftData

/// iOS single-screen recorder. Mic-only by design (iOS has no public system-audio API).
/// Three tabs over the same transcript stream: Live, Polished, Topics.
struct RecordView: View {
    @Environment(\.modelContext) private var context
    @StateObject private var audio = AudioCaptureService()
    @StateObject private var transcriber = TranscriptionService()
    @StateObject private var llm: LLMService
    @StateObject private var cheatsheet: CheatsheetGenerator
    @StateObject private var polisher: TranscriptPolisher

    @AppStorage("userName") private var userName: String = "Ming"
    @State private var currentMeeting: Meeting?
    @State private var pane: Pane = .live
    @State private var startError: String?
    @State private var loadError: String?
    @State private var sessionStorage: SessionStorage?
    @State private var audioPlayer: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var showDeleteConfirm = false

    private enum Pane: String, CaseIterable, Identifiable {
        case live = "Live"
        case polished = "Polished"
        case topics = "Topics"
        var id: String { rawValue }
    }

    init() {
        let llmInstance = LLMService()
        _llm = StateObject(wrappedValue: llmInstance)
        _cheatsheet = StateObject(wrappedValue: CheatsheetGenerator(llm: llmInstance))
        _polisher = StateObject(wrappedValue: TranscriptPolisher(llm: llmInstance))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if !llm.isLoaded {
                    LoadingBanner(progress: llm.loadProgress, modelName: LLMService.recommendedModel().displayName)
                }

                Picker("View", selection: $pane) {
                    ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                Group {
                    switch pane {
                    case .live:
                        TranscriptView(
                            confirmed: transcriber.confirmedTranscript,
                            interim: transcriber.unconfirmedText
                        )
                    case .polished:
                        PolishedTranscriptView(
                            finalizedParagraphs: polisher.finalizedParagraphs,
                            currentDraft: polisher.currentDraft,
                            rawFallback: transcriber.liveTranscript
                        )
                    case .topics:
                        TopicsPane(sheet: cheatsheet.current)
                    }
                }
                .padding(.horizontal)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                RecordButton(isRecording: audio.isRecording, action: toggleRecording)
                    .padding(.bottom, 24)
            }
            .navigationTitle("MeetMate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Copy transcript", systemImage: "doc.on.doc") { copyTranscript() }
                            .disabled(transcriber.confirmedTranscript.isEmpty)
                        ShareLink(item: transcriber.confirmedTranscript)
                            .disabled(transcriber.confirmedTranscript.isEmpty)

                        if !audio.isRecording, currentMeeting != nil {
                            Divider()
                            Button("Play mic recording", systemImage: isPlaying ? "pause.circle" : "play.circle") {
                                togglePlayback()
                            }
                            .disabled(!(currentMeeting?.hasSessionFolder ?? false))

                            Button("Delete meeting", systemImage: "trash", role: .destructive) {
                                showDeleteConfirm = true
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .alert("Couldn't start recording", isPresented: Binding(get: { startError != nil }, set: { if !$0 { startError = nil } })) {
            Button("OK", role: .cancel) { startError = nil }
        } message: { Text(startError ?? "") }
        .alert("Model failed to load", isPresented: Binding(get: { loadError != nil }, set: { if !$0 { loadError = nil } })) {
            Button("OK", role: .cancel) { loadError = nil }
        } message: { Text(loadError ?? "") }
        .confirmationDialog("Delete this meeting?", isPresented: $showDeleteConfirm) {
            Button("Delete meeting & files", role: .destructive) { deleteMeeting() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the recording, transcript, and all session files.")
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

    private func toggleRecording() {
        if audio.isRecording {
            stopMeeting()
        } else {
            startMeeting()
        }
    }

    private func startMeeting() {
        let now = Date()
        let meeting = Meeting(title: "Meeting \(now.formatted(date: .abbreviated, time: .shortened))", startedAt: now)
        context.insert(meeting)
        currentMeeting = meeting
        transcriber.reset()
        isPlaying = false
        audioPlayer = nil

        var storage: SessionStorage?
        do {
            storage = try SessionStorage(startedAt: now, isSystemAudioAvailable: false)
            sessionStorage = storage
            transcriber.sessionStorage = storage
            polisher.sessionStorage = storage
            cheatsheet.sessionStorage = storage
        } catch {
            print("[Meeting] failed to create session storage:", error)
        }

        audio.onAudioBuffer = { [weak transcriber] buffer in
            Task { @MainActor in
                transcriber?.ingest(buffer)
            }
        }

        if let writer = storage {
            audio.onMicBuffer = { [weak writer] buffer in
                writer?.writeMicBuffer(buffer)
            }
        } else {
            audio.onMicBuffer = nil
        }

        Task {
            do {
                try await audio.start()
            } catch {
                print("[Meeting] audio start failed:", error)
                startError = error.localizedDescription
                context.delete(meeting)
                currentMeeting = nil
                sessionStorage = nil
                return
            }
            cheatsheet.startRolling { transcriber.liveTranscript }
            polisher.start(reading: transcriber)
        }
    }

    private func stopMeeting() {
        audio.stop()
        cheatsheet.stopRolling()
        polisher.stop()
        currentMeeting?.endedAt = .now

        if let storage = sessionStorage {
            storage.writePolished(paragraphs: polisher.finalizedParagraphs, draft: polisher.currentDraft)
            storage.writeCheatsheet(
                topic: cheatsheet.current.currentTopic,
                keyPoints: cheatsheet.current.keyPoints,
                questions: cheatsheet.current.openQuestions,
                actions: cheatsheet.current.actionItems
            )
            storage.finalizeAudio()
        }

        transcriber.sessionStorage = nil
        polisher.sessionStorage = nil
        cheatsheet.sessionStorage = nil
    }

    private func copyTranscript() {
        let text = transcriber.confirmedTranscript
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }

    private func togglePlayback() {
        if let player = audioPlayer, player.isPlaying {
            player.pause()
            isPlaying = false
            return
        }

        if audioPlayer == nil, let meeting = currentMeeting {
            let micURL = meeting.sessionFolderURL.appendingPathComponent("mic.m4a")
            guard FileManager.default.fileExists(atPath: micURL.path) else { return }
            audioPlayer = try? AVAudioPlayer(contentsOf: micURL)
            audioPlayer?.prepareToPlay()
        }

        audioPlayer?.play()
        isPlaying = audioPlayer?.isPlaying ?? false
    }

    private func deleteMeeting() {
        guard let meeting = currentMeeting else { return }
        try? FileManager.default.removeItem(at: meeting.sessionFolderURL)
        context.delete(meeting)
        currentMeeting = nil
        sessionStorage = nil
        audioPlayer = nil
        isPlaying = false
    }
}

private struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isRecording ? Color.red.opacity(0.15) : Color.accentColor.opacity(0.15))
                    .frame(width: 88, height: 88)
                Image(systemName: isRecording ? "stop.circle.fill" : "record.circle")
                    .resizable()
                    .frame(width: 64, height: 64)
                    .foregroundStyle(isRecording ? .red : .accentColor)
                    .symbolEffect(.pulse, options: .repeating, isActive: isRecording)
            }
        }
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

private struct LoadingBanner: View {
    let progress: Double
    let modelName: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Loading \(modelName)…").font(.caption).bold()
                if progress > 0 {
                    ProgressView(value: progress)
                } else {
                    Text("First run downloads model files. WiFi recommended.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
    }
}

private struct TopicsPane: View {
    let sheet: Cheatsheet

    private var isEmpty: Bool {
        sheet.currentTopic.isEmpty && sheet.keyPoints.isEmpty && sheet.openQuestions.isEmpty && sheet.actionItems.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isEmpty {
                    Text("Topic summary appears once the meeting has ~30s of speech.")
                        .foregroundStyle(.secondary)
                } else {
                    if !sheet.currentTopic.isEmpty {
                        Section(header: Text("Topic").font(.headline)) {
                            Text(sheet.currentTopic).textSelection(.enabled)
                        }
                    }
                    if !sheet.keyPoints.isEmpty {
                        Section(header: Text("Key points").font(.headline)) {
                            ForEach(sheet.keyPoints, id: \.self) { Text("• \($0)") }
                        }
                    }
                    if !sheet.openQuestions.isEmpty {
                        Section(header: Text("Open questions").font(.headline)) {
                            ForEach(sheet.openQuestions, id: \.self) { Text("• \($0)") }
                        }
                    }
                    if !sheet.actionItems.isEmpty {
                        Section(header: Text("Action items").font(.headline)) {
                            ForEach(sheet.actionItems, id: \.self) { Text("• \($0)") }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
#endif

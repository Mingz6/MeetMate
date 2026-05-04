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
    @State private var sessionStorage: SessionStorage?
    @State private var audioPlayer: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var showDeleteConfirm = false
    @StateObject private var contextService = ContextService()
    @State private var showContext = false
    @State private var batchReTranscriber: BatchReTranscriber?

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
                Toggle(isOn: $showContext) { Label("Context", systemImage: "doc.text") }
                Spacer()
                Button(action: copyTranscript) {
                    Label("Copy transcript", systemImage: "doc.on.doc")
                }
                .disabled(transcriber.confirmedTranscript.isEmpty)
                .help("Copy confirmed transcript to clipboard")

                if !audio.isRecording, currentMeeting != nil {
                    Divider().frame(height: 16)

                    Button(action: togglePlayback) {
                        Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.circle" : "play.circle")
                    }
                    .disabled(!(currentMeeting?.hasSessionFolder ?? false))
                    .help("Play back mic recording")

                    Button(action: showInFinder) {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .disabled(!(currentMeeting?.hasSessionFolder ?? false))
                    .help("Open session folder in Finder")

                    Button(role: .destructive, action: { showDeleteConfirm = true }) {
                        Label("Delete", systemImage: "trash")
                    }
                    .help("Delete this meeting and its files")
                }
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal)

            if !llm.isLoaded && llm.activeProvider != .cloud {
                ModelLoadingBanner(progress: llm.loadProgress, modelName: LLMService.recommendedModel().displayName)
                    .padding(.horizontal)
            }

            // Provider status bar
            HStack(spacing: 12) {
                ProviderStatusBar(llm: llm)
                Divider().frame(height: 12)
                STTStatusIndicator(mode: transcriber.sttMode, vadSavings: transcriber.vadGate.savingsRatio)
            }
            .padding(.horizontal)

            // Batch re-transcription status
            if let batch = batchReTranscriber {
                BatchReTranscriptionBanner(batch: batch, onAccept: acceptBatchTranscript, onDismiss: dismissBatchTranscript)
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
                if showContext {
                    ContextPane(contextService: contextService)
                        .frame(width: 320)
                }
                if !showLive && !showPolished && !showCheatsheet && !showContext {
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
        .confirmationDialog("Delete this meeting?", isPresented: $showDeleteConfirm) {
            Button("Delete meeting & files", role: .destructive) { deleteMeeting() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the recording, transcript, and all session files.")
        }
        .task {
            // Configure cloud STT from Keychain
            let speechRegion = KeychainHelper.get(forKey: KeychainHelper.azureSpeechRegionKey) ?? ""
            let speechKey = KeychainHelper.get(forKey: KeychainHelper.azureSpeechKeyKey) ?? ""
            if !speechRegion.isEmpty && !speechKey.isEmpty {
                transcriber.configureCloudSTT(region: speechRegion, apiKey: speechKey)
            }

            // Load local Whisper model (fallback or primary if no cloud STT)
            do {
                try await transcriber.loadModel()
            } catch {
                print("[Whisper] loadModel failed:", error)
                // Non-fatal if cloud STT is configured
                if speechRegion.isEmpty || speechKey.isEmpty {
                    loadError = "Whisper: \(error.localizedDescription)"
                }
            }

            // Resolve STT mode based on what's available
            transcriber.resolveMode(
                networkAvailable: llm.reachability.isNetworkAvailable,
                cloudAvailable: llm.reachability.isCloudAvailable
            )

            // Load local LLM model as fallback — non-fatal if cloud is configured
            do {
                let override = UserDefaults.standard.string(forKey: "modelChoiceOverride") ?? ""
                let choice = LLMService.ModelChoice(rawValue: override)
                try await llm.loadLocalModel(choice)
            } catch {
                print("[LLM] local model load failed:", error)
                if llm.activeProvider == .recordingOnly {
                    loadError = "LLM: \(error.localizedDescription)"
                }
            }
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

        // Create session storage for disk persistence
        var storage: SessionStorage?
        do {
            let isSystemAvailable: Bool
            #if os(macOS)
            isSystemAvailable = true
            #else
            isSystemAvailable = false
            #endif
            storage = try SessionStorage(startedAt: now, isSystemAudioAvailable: isSystemAvailable)
            sessionStorage = storage
            transcriber.sessionStorage = storage
            polisher.sessionStorage = storage
            cheatsheet.sessionStorage = storage
        } catch {
            print("[Meeting] failed to create session storage:", error)
            // Non-fatal — recording works without disk persistence
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
            audio.onSystemBuffer = { [weak writer] buffer in
                writer?.writeSystemBuffer(buffer)
            }
        } else {
            audio.onMicBuffer = nil
            audio.onSystemBuffer = nil
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
            // Start cloud STT if in cloud mode
            if transcriber.sttMode == .cloud {
                // Inject vocabulary for phrase list biasing
                transcriber.vocabularyTerms = contextService.mergedVocabulary
                await transcriber.startCloudRecognition()
            } else {
                // For local mode, set vocabulary for WhisperKit prompt conditioning
                transcriber.vocabularyTerms = contextService.mergedVocabulary
            }

            // Wire context provider into consumers
            let ctxProvider: () -> String = { [weak contextService] in contextService?.combinedContext ?? "" }
            polisher.contextProvider = ctxProvider
            cheatsheet.contextProvider = ctxProvider
            replier.contextProvider = ctxProvider

            // Persist context to session folder
            if let storage {
                contextService.persist(to: storage)
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

        // Stop cloud STT
        Task {
            await transcriber.stopCloudRecognition()
        }

        // Final flush — write latest polished + cheatsheet, close audio files
        if let storage = sessionStorage {
            storage.writePolished(paragraphs: polisher.finalizedParagraphs, draft: polisher.currentDraft)
            storage.writeCheatsheet(
                topic: cheatsheet.current.currentTopic,
                keyPoints: cheatsheet.current.keyPoints,
                questions: cheatsheet.current.openQuestions,
                actions: cheatsheet.current.actionItems
            )
            storage.finalizeAudio()

            // Queue batch re-transcription if cloud STT was active
            startBatchReTranscription(sessionFolder: storage.sessionFolder)
        }

        transcriber.sessionStorage = nil
        polisher.sessionStorage = nil
        cheatsheet.sessionStorage = nil
    }

    private func startBatchReTranscription(sessionFolder: URL) {
        let speechRegion = KeychainHelper.get(forKey: KeychainHelper.azureSpeechRegionKey) ?? ""
        let speechKey = KeychainHelper.get(forKey: KeychainHelper.azureSpeechKeyKey) ?? ""
        guard !speechRegion.isEmpty, !speechKey.isEmpty else { return }

        let retranscriber = BatchReTranscriber(region: speechRegion, apiKey: speechKey)
        self.batchReTranscriber = retranscriber
        let vocabulary = contextService.mergedVocabulary

        Task {
            await retranscriber.reTranscribe(sessionFolder: sessionFolder, vocabulary: vocabulary)
        }
    }

    private func acceptBatchTranscript() {
        guard let batch = batchReTranscriber else { return }
        let batchText = batch.batchTranscriptText
        guard !batchText.isEmpty else {
            batchReTranscriber = nil
            return
        }
        // Replace the live transcript with the batch version
        // The batch file (transcript.batch.jsonl) is already persisted
        // Update the in-memory confirmed transcript for display
        transcriber.replaceConfirmedTranscript(with: batchText)
        batchReTranscriber = nil
        print("[Batch] user accepted improved transcript")
    }

    private func dismissBatchTranscript() {
        batchReTranscriber = nil
        print("[Batch] user kept original transcript")
    }

    private func showInFinder() {
        guard let meeting = currentMeeting else { return }
        let url = meeting.sessionFolderURL
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    private func deleteMeeting() {
        guard let meeting = currentMeeting else { return }
        // Delete session folder from disk
        try? FileManager.default.removeItem(at: meeting.sessionFolderURL)
        // Delete SwiftData record
        context.delete(meeting)
        currentMeeting = nil
        sessionStorage = nil
        audioPlayer = nil
        isPlaying = false
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
                paragraphs: polisher.paragraphs,
                currentDraft: polisher.currentDraft,
                rawFallback: transcriber.liveTranscript,
                onSeek: seekAudio
            )
        case (true, true):
            HStack(alignment: .top, spacing: 12) {
                TranscriptView(
                    confirmed: transcriber.confirmedTranscript,
                    interim: transcriber.unconfirmedText
                )
                .frame(maxWidth: .infinity)
                PolishedTranscriptView(
                    paragraphs: polisher.paragraphs,
                    currentDraft: polisher.currentDraft,
                    rawFallback: transcriber.liveTranscript,
                    onSeek: seekAudio
                )
                .frame(maxWidth: .infinity)
            }
        case (false, false):
            EmptyView()
        }
    }

    private func seekAudio(_ seconds: Float) {
        if audioPlayer == nil, let meeting = currentMeeting {
            let micURL = meeting.sessionFolderURL.appendingPathComponent("mic.m4a")
            guard FileManager.default.fileExists(atPath: micURL.path) else { return }
            audioPlayer = try? AVAudioPlayer(contentsOf: micURL)
            audioPlayer?.prepareToPlay()
        }
        guard let player = audioPlayer else { return }
        player.currentTime = TimeInterval(seconds)
        player.play()
        isPlaying = true
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

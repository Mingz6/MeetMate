#if os(macOS)
import SwiftUI
import Combine

/// Plays `DemoScript` through the same pane views the live app uses.
/// Start it with the `--demo` launch argument. Nothing here records, saves or calls the network.
@MainActor
final class DemoPlayer: ObservableObject {
    @Published private(set) var state = DemoState()
    @Published private(set) var stepIndex = 0

    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        let interval = DemoMode.stepInterval
        task = Task { [weak self] in
            // Let the window settle before the first frame.
            try? await Task.sleep(for: .seconds(DemoMode.startDelay))
            while !Task.isCancelled {
                guard let self, self.stepIndex < DemoScript.stepCount else { return }
                var next = self.state
                DemoScript.apply(stepAt: self.stepIndex, to: &next)
                withAnimation(.easeInOut(duration: 0.25)) {
                    self.state = next
                    self.stepIndex += 1
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func acceptRevision(_ revision: ParagraphRevision) {
        guard let index = state.paragraphs.firstIndex(where: { $0.id == revision.replaceIds.first }) else { return }
        let old = state.paragraphs[index]
        state.paragraphs[index] = PolishedParagraph(
            id: old.id, text: revision.newText,
            startSec: old.startSec, endSec: old.endSec,
            version: old.version + 1, source: old.source
        )
        state.revisions.removeAll { $0.id == revision.id }
    }

    func rejectRevision(_ revision: ParagraphRevision) {
        state.revisions.removeAll { $0.id == revision.id }
    }

    func dismissSuggestion() {
        state.suggestion = nil
    }
}

struct DemoMeetingView: View {
    @StateObject private var player = DemoPlayer()
    @State private var showLive = true
    @State private var showPolished = true
    @State private var showCheatsheet = true

    var body: some View {
        let state = player.state
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                if state.isRecording {
                    HStack(spacing: 6) {
                        RecordingDot()
                        Label("Stop", systemImage: "stop.circle.fill").foregroundStyle(.red)
                    }
                }
                Divider().frame(height: 16)
                Toggle(isOn: $showLive) { Label("Live", systemImage: "waveform") }
                Toggle(isOn: $showPolished) { Label("Polished", systemImage: "wand.and.stars") }
                Toggle(isOn: $showCheatsheet) { Label("Topic summary", systemImage: "lightbulb") }
                Spacer()
                Text("Demo: scripted sample meeting, nothing is recorded")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.2), in: Capsule())
                    .foregroundStyle(.orange)
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal)

            HStack(spacing: 12) {
                ProviderStatusLine(
                    provider: .cloud,
                    cloudPaused: false,
                    usage: state.usage,
                    onTogglePause: {}
                )
                Divider().frame(height: 12)
                STTStatusIndicator(mode: .cloud, vadSavings: state.vadSavings)
            }
            .padding(.horizontal)

            HStack(spacing: 16) {
                if showLive || showPolished {
                    VStack(alignment: .leading, spacing: 8) {
                        transcriptPane(state)
                        HStack(spacing: 8) {
                            Image(systemName: state.revisions.isEmpty ? "wand.and.stars.inverse" : "wand.and.stars")
                            Text("polished \(state.paragraphs.count) paragraphs · \(state.revisions.isEmpty ? "idle" : "updating…")")
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                if showCheatsheet {
                    CheatsheetView(
                        sheet: state.sheet,
                        suggestion: state.suggestion,
                        onDismissSuggestion: player.dismissSuggestion
                    )
                    .frame(width: 400)
                }
            }
            .padding([.horizontal, .bottom])
        }
        .padding(.top, 8)
        .frame(minWidth: 1120, idealWidth: 1180, minHeight: 560, idealHeight: 600)
        .onAppear { player.start() }
        .onDisappear { player.stop() }
    }

    @ViewBuilder
    private func transcriptPane(_ state: DemoState) -> some View {
        let live = TranscriptView(confirmed: state.confirmed, interim: state.interim)
        let polished = PolishedTranscriptView(
            paragraphs: state.paragraphs,
            currentDraft: state.draft,
            rawFallback: state.confirmed,
            pendingRevisions: state.revisions,
            onAcceptRevision: { player.acceptRevision($0) },
            onRejectRevision: { player.rejectRevision($0) }
        )
        switch (showLive, showPolished) {
        case (true, true):
            HStack(alignment: .top, spacing: 12) {
                live.frame(maxWidth: .infinity)
                polished.frame(maxWidth: .infinity)
            }
        case (true, false): live
        case (false, true): polished
        case (false, false): EmptyView()
        }
    }
}
#endif

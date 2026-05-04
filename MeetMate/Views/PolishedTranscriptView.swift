import SwiftUI

/// Renders polished transcript as discrete paragraphs with timestamps.
/// Clicking a timestamp seeks the audio to that position.
/// Shows pending revisions from §6 re-polish with accept/reject actions.
struct PolishedTranscriptView: View {
    let paragraphs: [PolishedParagraph]
    let currentDraft: String
    let rawFallback: String
    let pendingRevisions: [ParagraphRevision]
    var onSeek: ((Float) -> Void)?
    var onAcceptRevision: ((ParagraphRevision) -> Void)?
    var onRejectRevision: ((ParagraphRevision) -> Void)?
    var sessionStorage: SessionStorage?

    init(
        paragraphs: [PolishedParagraph],
        currentDraft: String,
        rawFallback: String,
        pendingRevisions: [ParagraphRevision] = [],
        onSeek: ((Float) -> Void)? = nil,
        onAcceptRevision: ((ParagraphRevision) -> Void)? = nil,
        onRejectRevision: ((ParagraphRevision) -> Void)? = nil,
        sessionStorage: SessionStorage? = nil
    ) {
        self.paragraphs = paragraphs
        self.currentDraft = currentDraft
        self.rawFallback = rawFallback
        self.pendingRevisions = pendingRevisions
        self.onSeek = onSeek
        self.onAcceptRevision = onAcceptRevision
        self.onRejectRevision = onRejectRevision
        self.sessionStorage = sessionStorage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Polished transcript")
                .font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if paragraphs.isEmpty && currentDraft.isEmpty {
                            Text(rawFallback.isEmpty ? "Waiting for audio…" : "Listening — first polished paragraph will appear in ~30s.\n\nRaw stream:\n\(rawFallback)")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(paragraphs) { para in
                                ParagraphRow(
                                    paragraph: para,
                                    onSeek: onSeek,
                                    revision: pendingRevisions.first { $0.replaceIds.contains(para.id) },
                                    sessionStorage: sessionStorage
                                )
                                .id(para.id)
                            }
                            if !currentDraft.isEmpty {
                                DraftRow(text: currentDraft)
                                    .id("draft")
                            }
                        }

                        // Pending revisions section
                        if !pendingRevisions.isEmpty {
                            Divider()
                            Text("Suggested revisions")
                                .font(.subheadline.bold())
                                .foregroundStyle(.orange)
                            ForEach(pendingRevisions) { rev in
                                RevisionCard(
                                    revision: rev,
                                    originalTexts: paragraphs.filter { rev.replaceIds.contains($0.id) }.map(\.text),
                                    onAccept: { onAcceptRevision?(rev) },
                                    onReject: { onRejectRevision?(rev) }
                                )
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: paragraphs.count) { _, _ in
                    withAnimation { proxy.scrollTo("draft", anchor: .bottom) }
                }
                .onChange(of: currentDraft) { _, _ in
                    withAnimation { proxy.scrollTo("draft", anchor: .bottom) }
                }
            }
        }
    }
}

private struct ParagraphRow: View {
    let paragraph: PolishedParagraph
    var onSeek: ((Float) -> Void)?
    var revision: ParagraphRevision?
    @State private var showHistory = false
    @State private var versionHistory: [PolishedParagraph] = []
    var sessionStorage: SessionStorage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    Button(action: { onSeek?(paragraph.startSec) }) {
                        Text(paragraph.timestampLabel)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .help("Seek to \(paragraph.timestampLabel)")

                    if let label = paragraph.speakerLabel {
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(paragraph.source == .mic ? .green : .purple)
                    }
                }
                .frame(width: 48, alignment: .trailing)

                VStack(alignment: .leading, spacing: 2) {
                    Text(paragraph.text)
                        .textSelection(.enabled)
                        .strikethrough(revision != nil, color: .red)
                        .foregroundStyle(revision != nil ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if paragraph.version > 1 {
                        Button(action: {
                            if let storage = sessionStorage {
                                versionHistory = storage.loadVersionHistory(forId: paragraph.id)
                            }
                            showHistory = true
                        }) {
                            Text("v\(paragraph.version)")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showHistory) {
                            VersionHistoryPopover(versions: versionHistory)
                        }
                    }
                }
            }
        }
    }
}

private struct VersionHistoryPopover: View {
    let versions: [PolishedParagraph]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit history")
                .font(.headline)
            if versions.isEmpty {
                Text("No version history available")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(versions, id: \.version) { ver in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("v\(ver.version)")
                            .font(.caption.bold())
                            .foregroundStyle(ver.version == versions.last?.version ? .orange : .secondary)
                        Text(ver.text)
                            .font(.callout)
                            .strikethrough(ver.version != versions.last?.version, color: .red)
                            .foregroundStyle(ver.version == versions.last?.version ? .primary : .secondary)
                    }
                    if ver.version != versions.last?.version {
                        Divider()
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 300, maxWidth: 400)
    }
}

private struct RevisionCard: View {
    let revision: ParagraphRevision
    let originalTexts: [String]
    let onAccept: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Original (struck through)
            ForEach(originalTexts, id: \.self) { text in
                Text(text)
                    .strikethrough(color: .red)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            // Proposed replacement
            Text(revision.newText)
                .foregroundStyle(.green)
                .font(.callout)
            // Reason
            if !revision.reason.isEmpty {
                Text(revision.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
            }
            // Actions
            HStack(spacing: 12) {
                Button(action: onAccept) {
                    Label("Accept", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.small)

                Button(action: onReject) {
                    Label("Reject", systemImage: "xmark.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct DraftRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
                .frame(width: 48)
            Text(text)
                .italic()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

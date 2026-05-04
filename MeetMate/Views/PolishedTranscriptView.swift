import SwiftUI

/// Renders polished transcript as discrete paragraphs with timestamps.
/// Clicking a timestamp seeks the audio to that position.
struct PolishedTranscriptView: View {
    let paragraphs: [PolishedParagraph]
    let currentDraft: String
    let rawFallback: String
    var onSeek: ((Float) -> Void)?

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
                                ParagraphRow(paragraph: para, onSeek: onSeek)
                                    .id(para.id)
                            }
                            if !currentDraft.isEmpty {
                                DraftRow(text: currentDraft)
                                    .id("draft")
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

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: { onSeek?(paragraph.startSec) }) {
                Text(paragraph.timestampLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .help("Seek to \(paragraph.timestampLabel)")
            .frame(width: 48, alignment: .trailing)
            Text(paragraph.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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

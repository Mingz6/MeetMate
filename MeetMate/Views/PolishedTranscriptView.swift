import SwiftUI

/// Renders polished transcript as discrete paragraphs you can select + reference,
/// plus a visually-distinct trailing draft for the in-progress thought.
struct PolishedTranscriptView: View {
    let finalizedParagraphs: [String]
    let currentDraft: String
    let rawFallback: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Polished transcript")
                .font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if finalizedParagraphs.isEmpty && currentDraft.isEmpty {
                            Text(rawFallback.isEmpty ? "Waiting for audio…" : "Listening — first polished paragraph will appear in ~30s.\n\nRaw stream:\n\(rawFallback)")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(Array(finalizedParagraphs.enumerated()), id: \.offset) { index, paragraph in
                                ParagraphRow(index: index + 1, text: paragraph)
                                    .id("p-\(index)")
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
                .onChange(of: finalizedParagraphs.count) { _, _ in
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
    let index: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
            Text(text)
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
                .frame(width: 24)
            Text(text)
                .italic()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

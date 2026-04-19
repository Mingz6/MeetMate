import SwiftUI

struct CheatsheetView: View {
    let sheet: Cheatsheet
    let suggestion: ReplySuggestion?
    let onDismissSuggestion: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let suggestion {
                    SuggestionCard(suggestion: suggestion, onDismiss: onDismissSuggestion)
                }

                Section("Current topic") {
                    Text(sheet.currentTopic.isEmpty ? "—" : sheet.currentTopic)
                        .font(.title3).bold()
                }

                Section("Key points") {
                    bulletList(sheet.keyPoints)
                }

                Section("Open questions") {
                    bulletList(sheet.openQuestions)
                }

                Section("Action items") {
                    bulletList(sheet.actionItems)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func bulletList(_ items: [String]) -> some View {
        if items.isEmpty {
            Text("—").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top) {
                        Text("•")
                        Text(item)
                    }
                }
            }
        }
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption).bold()
                .foregroundStyle(.secondary)
            content()
        }
    }
}

private struct SuggestionCard: View {
    let suggestion: ReplySuggestion
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Suggested reply", systemImage: "bubble.left.and.bubble.right.fill")
                    .font(.caption).bold()
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
            }
            Text(suggestion.suggestedReply)
                .textSelection(.enabled)
        }
        .padding()
        .background(Color.yellow.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

import SwiftUI
import UniformTypeIdentifiers

/// Pre-meeting context input pane — notes, URL fetch, PDF drop.
struct ContextPane: View {
    @ObservedObject var contextService: ContextService
    @State private var urlInput: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Meeting Context")
                    .font(.headline)
                Spacer()
                if contextService.hasContext {
                    Text("~\(contextService.approximateTokens) tokens")
                        .font(.caption2)
                        .foregroundStyle(contextService.isNearLimit ? .orange : .secondary)
                }
                if contextService.hasContext {
                    Button("Clear all") { contextService.clear() }
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            // Free-form notes
            TextEditor(text: $contextService.freeformText)
                .font(.body)
                .frame(minHeight: 80, maxHeight: 150)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3))
                )
                .overlay(alignment: .topLeading) {
                    if contextService.freeformText.isEmpty {
                        Text("Paste notes, agenda, names, or terms…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }

            // URL fetch
            HStack {
                TextField("Fetch URL", text: $urlInput, prompt: Text("https://arxiv.org/abs/..."))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { fetchURL() }
                Button(action: fetchURL) {
                    if contextService.isFetching {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.circle")
                    }
                }
                .disabled(urlInput.isEmpty || contextService.isFetching)
            }

            if let error = contextService.fetchError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            // PDF drop zone
            PDFDropZone(contextService: contextService)

            // Preview of fetched/PDF content
            if !contextService.fetchedURLText.isEmpty || !contextService.pdfText.isEmpty {
                DisclosureGroup("Loaded reference (\(referenceCharCount) chars)") {
                    ScrollView {
                        Text(contextService.fetchedURLText.isEmpty ? contextService.pdfText : contextService.fetchedURLText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
                .font(.caption)
            }
        }
        .padding()
    }

    private var referenceCharCount: Int {
        contextService.fetchedURLText.count + contextService.pdfText.count
    }

    private func fetchURL() {
        let url = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        Task { await contextService.fetchURL(url) }
    }
}

// MARK: - PDF Drop Zone

private struct PDFDropZone: View {
    @ObservedObject var contextService: ContextService
    @State private var isTargeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isTargeted ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                    .foregroundStyle(isTargeted ? .blue : .secondary.opacity(0.4))
            )
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Drop PDF here")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 50)
            .onDrop(of: [.pdf, .fileURL], isTargeted: $isTargeted) { providers in
                handleDrop(providers)
            }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
            provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, _ in
                if let url {
                    DispatchQueue.main.async {
                        contextService.extractPDF(from: url)
                    }
                }
            }
            return true
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      url.pathExtension.lowercased() == "pdf" else { return }
                DispatchQueue.main.async {
                    contextService.extractPDF(from: url)
                }
            }
            return true
        }

        return false
    }
}

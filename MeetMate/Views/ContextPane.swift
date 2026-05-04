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

            // Vocabulary biasing
            VocabularySection(contextService: contextService)
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

// MARK: - Vocabulary Section

private struct VocabularySection: View {
    @ObservedObject var contextService: ContextService
    @State private var newTerm: String = ""
    @State private var showExtracted = false

    var body: some View {
        DisclosureGroup("Vocabulary biasing (\(contextService.mergedVocabulary.count) terms)") {
            VStack(alignment: .leading, spacing: 8) {
                // Add new term
                HStack {
                    TextField("Add term…", text: $newTerm)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addTerm() }
                    Button(action: addTerm) {
                        Image(systemName: "plus.circle")
                    }
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                // User terms (editable)
                if !contextService.userVocabulary.isEmpty {
                    Text("Custom terms").font(.caption2).foregroundStyle(.secondary)
                    FlowLayout(spacing: 4) {
                        ForEach(contextService.userVocabulary, id: \.self) { term in
                            TermChip(term: term, isUserTerm: true) {
                                contextService.removeVocabularyTerm(term)
                            }
                        }
                    }
                }

                // Auto-extracted (read-only, collapsible)
                let extracted = contextService.extractedVocabulary
                if !extracted.isEmpty {
                    DisclosureGroup("Auto-extracted (\(extracted.count))", isExpanded: $showExtracted) {
                        FlowLayout(spacing: 4) {
                            ForEach(extracted.prefix(30), id: \.self) { term in
                                TermChip(term: term, isUserTerm: false, onRemove: nil)
                            }
                            if extracted.count > 30 {
                                Text("+\(extracted.count - 30) more")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .font(.caption2)
                }
            }
        }
        .font(.caption)
    }

    private func addTerm() {
        contextService.addVocabularyTerm(newTerm)
        newTerm = ""
    }
}

// MARK: - Term Chip

private struct TermChip: View {
    let term: String
    let isUserTerm: Bool
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 2) {
            Text(term)
                .font(.caption2)
            if isUserTerm, let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(isUserTerm ? Color.blue.opacity(0.12) : Color.secondary.opacity(0.08))
        .clipShape(Capsule())
    }
}

// MARK: - Flow Layout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var height: CGFloat = 0
        for (index, row) in rows.enumerated() {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            height += rowHeight
            if index < rows.count - 1 { height += spacing }
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            var x = bounds.minX
            for subview in row {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubviews.Element]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutSubviews.Element]] = [[]]
        var currentWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentWidth + size.width + spacing > maxWidth && !rows[rows.count - 1].isEmpty {
                rows.append([])
                currentWidth = 0
            }
            rows[rows.count - 1].append(subview)
            currentWidth += size.width + spacing
        }
        return rows
    }
}

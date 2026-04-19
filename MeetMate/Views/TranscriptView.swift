import SwiftUI

struct TranscriptView: View {
    let confirmed: String
    let interim: String

    init(confirmed: String, interim: String = "") {
        self.confirmed = confirmed
        self.interim = interim
    }

    /// Backwards-compatible single-string init for callers that don't have an interim stream.
    init(text: String) {
        self.confirmed = text
        self.interim = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live transcript")
                .font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    if confirmed.isEmpty && interim.isEmpty {
                        Text("Waiting for audio…")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            if !confirmed.isEmpty {
                                Text(confirmed)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            if !interim.isEmpty {
                                Text(interim)
                                    .foregroundStyle(.secondary)
                                    .italic()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .id("interim-tail")
                            }
                        }
                        .padding(8)
                    }
                }
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: confirmed) { _, _ in
                    withAnimation { proxy.scrollTo("interim-tail", anchor: .bottom) }
                }
                .onChange(of: interim) { _, _ in
                    withAnimation { proxy.scrollTo("interim-tail", anchor: .bottom) }
                }
            }
        }
    }
}

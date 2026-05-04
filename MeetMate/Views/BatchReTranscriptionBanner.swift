import SwiftUI

/// Banner showing batch re-transcription progress and accept/reject controls.
struct BatchReTranscriptionBanner: View {
    @ObservedObject var batch: BatchReTranscriber
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        switch batch.status {
        case .idle:
            EmptyView()

        case .loading:
            statusRow(icon: "arrow.down.circle", text: "Loading audio for re-transcription…", color: .secondary)

        case .transcribing(let progress):
            HStack(spacing: 8) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .foregroundStyle(.blue)
                Text("Re-transcribing… \(Int(progress * 100))%")
                    .font(.caption)
                ProgressView(value: Double(progress))
                    .frame(width: 80)
            }
            .padding(.vertical, 4)

        case .complete(let count):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Improved transcript ready (\(count) segments)")
                        .font(.caption)
                    if batch.uniqueSpeakerCount > 1 {
                        Text("\(batch.uniqueSpeakerCount) speakers detected")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Accept") { onAccept() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Keep original") { onDismiss() }
                    .controlSize(.small)
            }
            .padding(.vertical, 4)

        case .failed(let reason):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Re-transcription failed: \(reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Dismiss") { onDismiss() }
                    .controlSize(.small)
            }
            .padding(.vertical, 4)
        }
    }

    private func statusRow(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

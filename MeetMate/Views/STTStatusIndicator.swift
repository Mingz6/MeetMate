import SwiftUI

/// Compact status indicator showing active STT mode + VAD savings.
struct STTStatusIndicator: View {
    let mode: TranscriptionService.STTMode
    let vadSavings: Float

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if mode == .cloud && vadSavings > 0 {
                Text("VAD \(Int(vadSavings * 100))% saved")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var dotColor: Color {
        switch mode {
        case .cloud: return .blue
        case .local: return .green
        case .recordingOnly: return .orange
        }
    }

    private var label: String {
        switch mode {
        case .cloud: return "Azure Speech"
        case .local: return "WhisperKit"
        case .recordingOnly: return "Recording only"
        }
    }
}

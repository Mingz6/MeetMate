import SwiftUI

/// Compact status bar showing which LLM provider is active and session cost.
struct ProviderStatusBar: View {
    @ObservedObject var llm: LLMService

    var body: some View {
        HStack(spacing: 8) {
            // Provider indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(providerColor)
                    .frame(width: 8, height: 8)
                Text(llm.activeProvider.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if llm.activeProvider == .recordingOnly {
                Text("— transcript + audio saved, LLM features paused")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Spacer()

            // Session cost (only when cloud has been used)
            if llm.sessionUsage.totalTokens > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "dollarsign.circle")
                        .font(.caption2)
                    Text("\(llm.sessionUsage.totalTokens) tokens · $\(llm.sessionUsage.estimatedCostUSD, specifier: "%.4f")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Pause/resume cloud toggle
            if llm.activeProvider == .cloud || llm.cloudPaused {
                Button(action: { llm.cloudPaused.toggle() }) {
                    Image(systemName: llm.cloudPaused ? "icloud.slash" : "icloud.fill")
                        .font(.caption)
                        .foregroundStyle(llm.cloudPaused ? .orange : .blue)
                }
                .buttonStyle(.plain)
                .help(llm.cloudPaused ? "Resume cloud LLM" : "Pause cloud LLM")
            }
        }
    }

    private var providerColor: Color {
        switch llm.activeProvider {
        case .cloud: return .blue
        case .local: return .green
        case .recordingOnly: return .orange
        }
    }
}

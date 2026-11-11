import SwiftUI

/// Compact status bar showing which LLM provider is active and session cost.
struct ProviderStatusBar: View {
    @ObservedObject var llm: LLMService

    var body: some View {
        ProviderStatusLine(
            provider: llm.activeProvider,
            cloudPaused: llm.cloudPaused,
            usage: llm.sessionUsage,
            onTogglePause: { llm.cloudPaused.toggle() }
        )
    }
}

/// The status bar's layout, driven by plain values so demo mode can render it without a live `LLMService`.
struct ProviderStatusLine: View {
    let provider: LLMService.ProviderMode
    let cloudPaused: Bool
    let usage: SessionTokenUsage
    let onTogglePause: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Provider indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(providerColor)
                    .frame(width: 8, height: 8)
                Text(provider.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if provider == .recordingOnly {
                Text("— transcript + audio saved, LLM features paused")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Spacer()

            // Session cost (only when cloud has been used)
            if usage.totalTokens > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "dollarsign.circle")
                        .font(.caption2)
                    Text("\(usage.totalTokens) tokens · $\(usage.estimatedCostUSD, specifier: "%.4f")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Pause/resume cloud toggle
            if provider == .cloud || cloudPaused {
                Button(action: onTogglePause) {
                    Image(systemName: cloudPaused ? "icloud.slash" : "icloud.fill")
                        .font(.caption)
                        .foregroundStyle(cloudPaused ? .orange : .blue)
                }
                .buttonStyle(.plain)
                .help(cloudPaused ? "Resume cloud LLM" : "Pause cloud LLM")
            }
        }
    }

    private var providerColor: Color {
        switch provider {
        case .cloud: return .blue
        case .local: return .green
        case .recordingOnly: return .orange
        }
    }
}

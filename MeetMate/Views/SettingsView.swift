import SwiftUI

struct SettingsView: View {
    @AppStorage("userName") private var userName: String = "Ming"
    @AppStorage("modelChoiceOverride") private var modelOverride: String = ""
    @AppStorage("meetingsArchivePath") private var archivePath: String = "~/Documents/MeetMate"

    private var recommended: LLMService.ModelChoice { LLMService.recommendedModel() }

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Your name (used to detect mentions)", text: $userName)
            }
            Section {
                Picker("Model", selection: $modelOverride) {
                    Text("Auto: \(recommended.displayName)").tag("")
                    ForEach(LLMService.ModelChoice.allCases) { choice in
                        Text("\(choice.displayName) — \(String(format: "%.1f", choice.approximateSizeGB)) GB")
                            .tag(choice.rawValue)
                    }
                }
            } header: {
                Text("LLM model")
            } footer: {
                Text("Auto picks the best model for this device's RAM. Override only if the auto choice is too slow.")
                    .font(.caption)
            }
            Section("Meeting archive") {
                TextField("Path", text: $archivePath)
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 360)
    }
}

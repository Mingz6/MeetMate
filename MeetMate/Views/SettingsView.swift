import SwiftUI

struct SettingsView: View {
    @AppStorage("userName") private var userName: String = "Ming"
    @AppStorage("modelChoiceOverride") private var modelOverride: String = ""
    @AppStorage("meetingsArchivePath") private var archivePath: String = "~/Documents/MeetMate"

    // Azure OpenAI fields — stored in Keychain, local state for editing
    @State private var azureEndpoint: String = ""
    @State private var azureDeployment: String = ""
    @State private var azureAPIKey: String = ""
    @State private var azureConfigured = false

    // Azure Speech fields
    @State private var speechRegion: String = ""
    @State private var speechAPIKey: String = ""
    @State private var speechConfigured = false

    private var recommended: LLMService.ModelChoice { LLMService.recommendedModel() }

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Your name (used to detect mentions)", text: $userName)
            }

            // MARK: - Azure OpenAI
            Section {
                TextField("Endpoint", text: $azureEndpoint, prompt: Text("https://your-resource.openai.azure.com"))
                TextField("Deployment name", text: $azureDeployment, prompt: Text("gpt-4o"))
                SecureField("API key", text: $azureAPIKey, prompt: Text("••••••••"))

                HStack {
                    if azureConfigured {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Configured")
                            .foregroundColor(.secondary)
                    } else {
                        Image(systemName: "xmark.circle")
                            .foregroundColor(.orange)
                        Text("Not configured")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Save to Keychain") {
                        saveAzureConfig()
                    }
                    .disabled(azureEndpoint.isEmpty || azureDeployment.isEmpty || azureAPIKey.isEmpty)

                    if azureConfigured {
                        Button("Clear") {
                            clearAzureConfig()
                        }
                        .foregroundColor(.red)
                    }
                }
            } header: {
                Text("Azure OpenAI (primary)")
            } footer: {
                Text("Cloud LLM for polish, cheatsheet, and replies. Keys are stored securely in the macOS Keychain.")
                    .font(.caption)
            }

            // MARK: - Azure Speech
            Section {
                TextField("Region", text: $speechRegion, prompt: Text("eastus"))
                SecureField("API key", text: $speechAPIKey, prompt: Text("••••••••"))

                HStack {
                    if speechConfigured {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Configured")
                            .foregroundColor(.secondary)
                    } else {
                        Image(systemName: "xmark.circle")
                            .foregroundColor(.orange)
                        Text("Not configured — using local WhisperKit")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Save to Keychain") {
                        saveSpeechConfig()
                    }
                    .disabled(speechRegion.isEmpty || speechAPIKey.isEmpty)

                    if speechConfigured {
                        Button("Clear") {
                            clearSpeechConfig()
                        }
                        .foregroundColor(.red)
                    }
                }
            } header: {
                Text("Azure AI Speech (cloud STT)")
            } footer: {
                Text("Cloud transcription — faster and more accurate than local. Same Azure resource as OpenAI recommended. Audio is streamed to Azure for recognition.")
                    .font(.caption)
            }

            // MARK: - Local model (fallback)
            Section {
                Picker("Model", selection: $modelOverride) {
                    Text("Auto: \(recommended.displayName)").tag("")
                    ForEach(LLMService.ModelChoice.allCases) { choice in
                        Text("\(choice.displayName) — \(String(format: "%.1f", choice.approximateSizeGB)) GB")
                            .tag(choice.rawValue)
                    }
                }
            } header: {
                Text("Local LLM (fallback)")
            } footer: {
                Text("Used when cloud is unavailable. Auto picks the best model for this device's RAM.")
                    .font(.caption)
            }

            Section("Meeting archive") {
                TextField("Path", text: $archivePath)
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 400)
        .onAppear {
            loadAzureConfig()
            loadSpeechConfig()
        }
    }

    // MARK: - Keychain helpers

    private func loadAzureConfig() {
        azureEndpoint = KeychainHelper.get(forKey: KeychainHelper.azureEndpointKey) ?? ""
        azureDeployment = KeychainHelper.get(forKey: KeychainHelper.azureDeploymentKey) ?? ""
        azureAPIKey = KeychainHelper.get(forKey: KeychainHelper.azureAPIKeyKey) ?? ""
        azureConfigured = !azureEndpoint.isEmpty && !azureDeployment.isEmpty && !azureAPIKey.isEmpty
    }

    private func saveAzureConfig() {
        KeychainHelper.set(azureEndpoint, forKey: KeychainHelper.azureEndpointKey)
        KeychainHelper.set(azureDeployment, forKey: KeychainHelper.azureDeploymentKey)
        KeychainHelper.set(azureAPIKey, forKey: KeychainHelper.azureAPIKeyKey)
        azureConfigured = true
    }

    private func clearAzureConfig() {
        KeychainHelper.delete(forKey: KeychainHelper.azureEndpointKey)
        KeychainHelper.delete(forKey: KeychainHelper.azureDeploymentKey)
        KeychainHelper.delete(forKey: KeychainHelper.azureAPIKeyKey)
        azureEndpoint = ""
        azureDeployment = ""
        azureAPIKey = ""
        azureConfigured = false
    }

    // MARK: - Speech Keychain helpers

    private func loadSpeechConfig() {
        speechRegion = KeychainHelper.get(forKey: KeychainHelper.azureSpeechRegionKey) ?? ""
        speechAPIKey = KeychainHelper.get(forKey: KeychainHelper.azureSpeechKeyKey) ?? ""
        speechConfigured = !speechRegion.isEmpty && !speechAPIKey.isEmpty
    }

    private func saveSpeechConfig() {
        KeychainHelper.set(speechRegion, forKey: KeychainHelper.azureSpeechRegionKey)
        KeychainHelper.set(speechAPIKey, forKey: KeychainHelper.azureSpeechKeyKey)
        speechConfigured = true
    }

    private func clearSpeechConfig() {
        KeychainHelper.delete(forKey: KeychainHelper.azureSpeechRegionKey)
        KeychainHelper.delete(forKey: KeychainHelper.azureSpeechKeyKey)
        speechRegion = ""
        speechAPIKey = ""
        speechConfigured = false
    }
}

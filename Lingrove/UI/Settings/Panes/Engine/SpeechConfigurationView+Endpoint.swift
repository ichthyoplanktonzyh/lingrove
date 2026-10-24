import SwiftUI

/// Speech keeps its own endpoint profile while sharing the engine page's model/connection layout.
extension SpeechConfigurationView {
    var endpointModelSection: some View {
        Section(String(localized: "Model", table: "Learning")) {
            endpointField(title: String(localized: "Model", table: "Learning"), value: speech.settings.endpointModel,
                systemImage: "shippingbox", set: speech.settings.setEndpointModel).settingsItem(.speechEndpointModel)
            LabeledContent(String(localized: "API format", table: "Learning"), value: "/audio/speech")
        }
    }

    var endpointVoiceSection: some View {
        Section(String(localized: "Voice", table: "Learning")) {
            voiceLanguagePicker
            endpointField(title: String(localized: "Voice identifier", table: "Learning"), value: speech.settings.endpointVoice,
                systemImage: "waveform", set: speech.settings.setEndpointVoice).settingsItem(.speechEndpointVoice)
        }
    }

    var endpointConnectionSection: some View {
        Section(String(localized: "Connection")) {
            endpointField(title: String(localized: "Server URL"), value: speech.settings.endpointBaseURL, systemImage: "network",
                set: speech.settings.setEndpointBaseURL).settingsItem(.speechEndpoint)
            LabeledContent {
                HStack(spacing: 8) {
                    SecureField("", text: $keyDraft, prompt: Text(String(localized: "Paste API key")))
                        .labelsHidden().textFieldStyle(.roundedBorder).frame(minWidth: 220, idealWidth: 280, maxWidth: 320)
                    Button(String(localized: "Save API key", table: "Learning")) {
                        do { try saveKeyIfNeeded() } catch { credentialError = error.localizedDescription }
                    }
                    .disabled(keyDraft == savedKey)
                }
            } label: {
                SettingsRowLabel(title: String(localized: "API Key"),
                    description: String(localized: "Optional bearer token stored securely in Keychain."),
                    systemImage: "key")
            }
            Text(String(localized: """
                Use a service that supports /audio/speech. Only the text you choose to read is sent; \
                reference audio and draft context are not sent.
                """,
                table: "Learning")).font(.caption).foregroundStyle(.secondary)
            if let configuration = try? speech.settings.endpointConfiguration(), configuration.endpoint.hostScope != .loopback {
                SettingsCalloutView(callout: .init(tone: .warning, message: String(
                    localized: "The selected text will be sent to this server outside your Mac when you click Read Aloud.",
                    table: "Learning")))
            }
            if let credentialError { Text(credentialError).font(.caption).foregroundStyle(.secondary) }
            if let error = speech.configurationError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(String(localized: "Configured. Use the voice test to verify this connection.", table: "Learning"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func endpointField(title: String, value: String, systemImage: String, set: @escaping (String) -> Void) -> some View {
        LabeledContent {
            TextField("", text: Binding(get: { value }, set: set))
                .labelsHidden().textFieldStyle(.roundedBorder).frame(minWidth: 220, idealWidth: 280, maxWidth: 320)
        } label: { SettingsRowLabel(title: title, description: "", systemImage: systemImage) }
    }

}

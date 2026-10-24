import SwiftUI

/// Local speech uses the original model picker, download rows, folder and installed-file rows.
/// The controller pairs known packages; these views never resolve files or load native weights.
extension SpeechConfigurationView {
    var localSections: some View {
        Group {
            Section(String(localized: "Model", table: "Learning")) {
                Picker(selection: Binding(get: {
                    let path = speech.settings.localModelPath
                    return SpeechModelPairingPolicy.isKnownDecoder(URL(fileURLWithPath: path).lastPathComponent) ? "" : path
                }, set: selectModel)) {
                    Text(String(localized: "Choose a model", table: "Learning")).tag("")
                    if !speech.settings.localModelPath.isEmpty,
                       !SpeechModelPairingPolicy.isKnownDecoder(URL(fileURLWithPath: speech.settings.localModelPath).lastPathComponent),
                       !speech.availableLocalModels.contains(where: { $0.url.path == speech.settings.localModelPath }) {
                        Text(URL(fileURLWithPath: speech.settings.localModelPath).lastPathComponent)
                            .tag(speech.settings.localModelPath)
                    }
                    ForEach(speech.availableLocalModels) { Text(SpeechModelCatalog.displayName(for: $0.filename)).tag($0.url.path) }
                } label: {
                    SettingsRowLabel(title: String(localized: "Selected model", table: "Learning"),
                        description: String(localized: "Choose from downloaded or imported GGUF files.", table: "Learning"),
                        systemImage: "shippingbox")
                }.pickerStyle(.menu).settingsItem(.speechModel)
                LabeledContent(String(localized: "Model status", table: "Learning"), value: runtimeStatus)
            }
        }
    }

    var decoderSection: some View {
        Section(String(localized: "Audio decoder", table: "Learning")) {
            Text(String(localized: """
                Use a matching Qwen3-TTS Base model and audio decoder. Optional WAV or MP3 reference audio guides the voice. \
                Processing stays on this Mac.
                """, table: "Learning")).font(.caption).foregroundStyle(.secondary)
            assetRow(title: String(localized: "Audio decoder", table: "Learning"),
                path: speech.settings.localProjectionPath, audio: false, set: speech.settings.setLocalProjectionPath)
                .settingsItem(.speechDecoder)
        }
    }

    var modelManagementSections: some View {
        Group {
            if !speech.availableLocalModels.isEmpty {
                Section(String(localized: "Installed", table: "Learning")) {
                    ForEach(speech.availableLocalModels) { model in
                        InstalledRuntimeModelRow(model: model, selected: model.url.path == speech.settings.localModelPath,
                            downloads: speech.modelDownloads, title: SpeechModelCatalog.displayName(for: model.filename),
                            select: { selectModel(model.url.path) },
                            delete: { pendingDeletion = model })
                    }
                }
            }
            Section(String(localized: "Get models", table: "Learning")) {
                DownloadableModelCatalogView(modelDownloadManager: speech.modelDownloads, onRefreshModels: refreshLocalModels,
                    showsImportHint: false)
            }
            ModelsFolderSection(downloads: speech.modelDownloads, refresh: speech.refreshLocalModels, allowsAdditionalSources: false)
        }
    }

    func refreshLocalModels() {
        speech.modelDownloads.refreshModelStates()
        speech.refreshLocalModels()
    }

    private func selectModel(_ path: String) {
        speech.selectLocalModel(path)
    }
}

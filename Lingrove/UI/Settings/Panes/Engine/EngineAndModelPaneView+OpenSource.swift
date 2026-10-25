import SwiftUI

/// Daily local configuration stays on the task page; file installation and deletion live in its
/// management sheet. The existing runtime/download services own selection and transfer lifetimes.
extension EngineAndModelPaneView {
    var openSourceSections: some View {
        Section(String(localized: "Model")) {
            Picker(selection: selectedModelBinding) {
                if let filename = runtimeModel.selectedModelFilename,
                   !runtimeModel.availableModels.contains(where: { $0.filename == filename }) {
                    Text(LocalModelSelectionLabel.unavailable(filename, task: .completion))
                        .tag(filename).selectionDisabled()
                }
                if runtimeModel.availableModels.isEmpty { Text(String(localized: "Choose a model", table: "Learning")).tag("") }
                ForEach(runtimeModel.availableModels) { Text($0.displayName).tag($0.filename) }
            } label: {
                SettingsRowLabel(title: String(localized: "Selected Model"),
                    description: String(localized: "Choose from downloaded or imported GGUF files.", table: "Learning"),
                    systemImage: "shippingbox")
            }
            .disabled(suggestionSettings.isPowerBasedModelSwitchingEnabled)
            .settingsItem(.selectedModel)
            LabeledContent(String(localized: "Model Status"), value: completionRuntimeStatus).settingsItem(.modelStatus)
        }
    }

    var modelManagementButton: some View {
        Button { navigation.openModelManager(.completion) } label: {
            Label(String(localized: "Manage models", table: "Learning"), systemImage: "shippingbox")
        }
    }

    private var completionRuntimeStatus: String {
        if let filename = runtimeModel.selectedModelFilename, !LocalModelTaskPolicy.supports(filename, task: .completion) {
            return String(localized: "This model is not compatible with this task. Choose another model.", table: "Learning")
        }
        return completionStatus
    }

    private var completionStatus: String {
        switch runtimeModel.state {
        case .idle:
            if runtimeModel.selectedModelFilename == nil {
                String(localized: "Choose a model", table: "Learning")
            } else {
                String(localized: "Configured · loads on first use", table: "Learning")
            }
        default: runtimeModel.state.summary
        }
    }

    var completionModelManagementSections: some View {
        Group {
            Section(String(localized: "Installed")) {
                ForEach(runtimeModel.availableModels) { model in
                    InstalledRuntimeModelRow(model: model, selected: model.filename == runtimeModel.selectedModelFilename,
                        downloads: modelDownloadManager,
                        select: suggestionSettings.isPowerBasedModelSwitchingEnabled ? nil : {
                            if suggestionSettings.keepsLocalRuntimeLoaded {
                                selectedModelBinding.wrappedValue = model.filename
                            } else {
                                runtimeModel.selectModelWithoutLoading(model.filename)
                            }
                        }, delete: { pendingDeletionModel = model })
                }
            }
            UnassignedLocalModelsSection(downloads: modelDownloadManager, task: .completion)
            Section(String(localized: "Get models", table: "Learning")) {
                DownloadableModelCatalogView(modelDownloadManager: modelDownloadManager, onRefreshModels: refreshModels)
                    .settingsItem(.downloadModels)
                HuggingFaceModelBrowserView(searchService: huggingFaceSearchService,
                    modelDownloadManager: modelDownloadManager, onRefreshModels: refreshModels)
                    .settingsItem(.huggingFaceBrowser)
            }
            ModelsFolderSection(downloads: modelDownloadManager, refresh: refreshModels)
        }
    }
}

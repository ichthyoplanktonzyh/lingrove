import SwiftUI

/// One folder/source editor is reused by all task pages. The global LM Studio preference matches
/// the existing locator. The download manager notifies all app-owned runtimes when sources change;
/// the page callback also keeps previews and isolated settings fixtures current.
struct ModelsFolderSection: View {
    @ObservedObject var downloads: ModelDownloadManager
    let refresh: () -> Void
    var allowsAdditionalSources = true
    @State private var lmStudioModelsURL: URL?
    @AppStorage(BundledRuntimeLocator.lmStudioSourceEnabledKey) private var lmStudioEnabled = false

    var body: some View {
        Section(String(localized: "Folder")) {
            LabeledContent {
                VStack(alignment: .trailing, spacing: 8) {
                    Text(downloads.modelsDirectoryPath).font(.callout.monospaced())
                        .textSelection(.enabled).multilineTextAlignment(.trailing)
                    HStack(spacing: 8) {
                        Button(String(localized: "Open Folder")) { downloads.openModelsDirectory() }
                        Button(String(localized: "Refresh")) { downloads.refreshSearchDirectories(); refresh() }
                    }
                }
            } label: {
                SettingsRowLabel(
                    title: String(localized: "Models Folder"),
                    description: String(localized: "Where downloaded model files are stored on this Mac."),
                    systemImage: "folder"
                )
            }
            .settingsItem(.modelsFolder)
            if allowsAdditionalSources {
                Toggle(isOn: $lmStudioEnabled) {
                    SettingsRowLabel(
                        title: String(localized: "Also Use LM Studio Models"),
                        description: lmStudioModelsURL == nil
                            ? String(localized: """
                            LM Studio's default model folder (~/.lmstudio/models) was not found, so this switch is unavailable. \
                            Only the default folder is currently supported.
                            """, comment: "Explains the missing default model folder, rather than assuming LM Studio is not installed.")
                            : String(localized: "Choose which models to use for this task under Custom models.", table: "Learning"),
                        systemImage: "square.stack.3d.up"
                    )
                }
                .disabled(lmStudioModelsURL == nil)
                .onChange(of: lmStudioEnabled) { _, _ in downloads.refreshSearchDirectories(); refresh() }
                .settingsItem(.lmStudio)
            }
        }
        .onAppear {
            guard allowsAdditionalSources else { return }
            lmStudioModelsURL = BundledRuntimeLocator.lmStudioModelsDirectoryIfAvailable()
            if lmStudioModelsURL == nil, lmStudioEnabled { lmStudioEnabled = false }
        }
    }
}

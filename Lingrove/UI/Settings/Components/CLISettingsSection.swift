import SwiftUI

/// A compact General settings entry reuses the app's grouped rows. Only the app-owned model
/// performs installation; the visible path also works when ~/.local/bin is absent from PATH.
struct CLISettingsSection: View {
    @ObservedObject var model: CLIInstallationModel
    var body: some View {
        Section(String(localized: "Command-line tools", table: "Vocabulary")) {
            HStack {
                SettingsRowLabel(title: model.command, description: model.path, systemImage: "terminal")
                Spacer()
                if model.installed {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        .accessibilityLabel(String(localized: "Installed"))
                } else {
                    Button(String(localized: "Install CLI", table: "Vocabulary")) { Task { await model.install() } }
                        .disabled(model.busy)
                }
            }.settingsItem(.commandLineTools)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.task { await model.refresh() }
    }
}

import SwiftUI

/// A task-scoped resource surface, presented by the existing model page. Owners inject their
/// app-owned download managers and selection actions; this view owns only sheet chrome. Model
/// files, transfers and credentials outlive presentation and remain with their existing services.
struct SettingsModelManagementSheet<Content: View>: View {
    let task: SettingsEngineTask
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Manage models", table: "Learning")).font(.headline)
                    Text(task.label).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "Done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            SettingsPaneScaffold(content: content)
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 480, idealHeight: 640)
    }
}

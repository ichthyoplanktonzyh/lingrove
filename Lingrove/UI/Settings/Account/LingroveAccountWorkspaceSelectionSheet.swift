// Extracted from Nibomo CloudWorkspaceSelectionSheet / CloudWorkspaceSelectionSupport (MIT).
// Copyright (c) 2026 Kirill Markin. License: Lingrove/Resources/NibomoUI-LICENSE.txt.
import LingroveCloud
import SwiftUI

/// This sheet observes the real workspace metadata and delegates an explicit choice to the
/// process-owned sync controller. Selection does not accept local material or enable sync. Its
/// native Form and toolbar inherit the presenting Settings window's resolved appearance.
struct LingroveAccountWorkspaceSelectionSheet: View {
    @ObservedObject var controller: MacNotebookSyncController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsPaneScaffold(callout: .init(tone: .info, message: String(localized: """
                Signing in only confirms your identity. Choose a workspace, decide what to do with \
                local material, then enable sync.
                """, table: "NotebookSync"))) {
                Section(LingroveNibomoAccountCopy.text("settings.currentWorkspace.section.chooseWorkspace")) {
                    ForEach(controller.workspaces) { workspace in
                        Button {
                            controller.chooseWorkspace(workspace.id)
                            dismiss()
                        } label: {
                            LingroveAccountWorkspaceRow(title: workspace.name,
                                showsSelectedIndicator: workspace.id == controller.selectedWorkspace?.id)
                        }
                        .buttonStyle(.plain)
                        .disabled(controller.isChoosingWorkspace || !controller.canAccessWorkspaces)
                        .accessibilityIdentifier("account.sync.workspace." + workspace.id)
                    }
                    if controller.workspaces.isEmpty {
                        Text(String(localized: "No workspaces are available for this account.", table: "NotebookSync"))
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    HStack(spacing: 8) {
                        if controller.isLoadingWorkspaces || controller.isChoosingWorkspace { ProgressView().controlSize(.small) }
                        LingroveSyncStatusIndicator(status: controller.workspaceStatus)
                        Spacer()
                        Button(String(localized: "Load workspaces", table: "NotebookSync")) { controller.refreshWorkspaces() }
                            .disabled(!controller.canAccessWorkspaces || controller.isLoadingWorkspaces || controller.isChoosingWorkspace)
                    }
                }
            }
            .navigationTitle(LingroveNibomoAccountCopy.text("settings.currentWorkspace.chooseWorkspaceTitle"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LingroveNibomoAccountCopy.text("common.close")) { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(width: 560, height: 480)
        .accessibilityIdentifier("account.sync.workspaceChooser")
    }
}

/// A workspace name is user data, rendered verbatim. The checkmark supplements the selected row's
/// accessibility trait, so the current scope remains distinguishable without relying on color.
private struct LingroveAccountWorkspaceRow: View {
    let title: String
    let showsSelectedIndicator: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if showsSelectedIndicator { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
        }
        .contentShape(Rectangle()).padding(.vertical, 4)
        .accessibilityAddTraits(showsSelectedIndicator ? .isSelected : [])
    }
}

/// Safe per-lane states retain their semantic color and an explicit text label in either
/// appearance. Working is progress, pending is caution, and unavailable/recovery remains distinct.
struct LingroveSyncStatusIndicator: View {
    let status: MacNotebookSyncStatus

    var body: some View {
        HStack(spacing: 6) {
            if status == .working {
                ProgressView().controlSize(.small)
            } else if let toneColor {
                Image(systemName: symbol).foregroundStyle(toneColor).accessibilityHidden(true)
            }
            Text(MacNotebookSyncPresentation.title(status)).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch status {
        case .synchronized: "checkmark.circle.fill"
        case .pending: "clock"
        default: "exclamationmark.circle"
        }
    }

    private var toneColor: Color? {
        switch status {
        case .synchronized: .green
        case .pending: .orange
        case .unavailable, .forbidden, .failed, .conflict, .rejected: .red
        default: nil
        }
    }
}

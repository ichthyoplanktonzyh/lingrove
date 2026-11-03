// Extracted from Nibomo CloudWorkspaceSelectionSheet / CloudWorkspaceSelectionSupport (MIT).
// Copyright (c) 2026 Kirill Markin. License: Lingrove/Resources/NibomoUI-LICENSE.txt.
import LingroveCloud
import SwiftUI

/// Nibomo’s workspace chooser uses the actual metadata supplied by the process-owned sync
/// controller. A row delegates one explicit selection to it; local retain/accept and sync opt-in
/// remain later steps. No guessed workspace, creation endpoint or guest capability is exposed.
struct LingroveAccountWorkspaceSelectionSheet: View {
    @ObservedObject var controller: MacNotebookSyncController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LingroveReadableContentLayout(maxWidth: lingroveReadableFormMaxWidth, horizontalPadding: 0) {
                List {
                    Section(String(localized: "Workspace", table: "NotebookSync")) {
                        Text(String(localized: """
                            Signing in only confirms your identity. Choose a workspace, decide what to do with \
                            local material, then enable sync.
                            """, table: "NotebookSync"))
                            .foregroundStyle(.secondary)
                    }
                    Section(LingroveNibomoAccountCopy.text("settings.currentWorkspace.section.chooseWorkspace")) {
                        ForEach(controller.workspaces) { workspace in
                            Button {
                                controller.chooseWorkspace(workspace.id)
                                dismiss()
                            } label: {
                                LingroveAccountWorkspaceRow(title: workspace.name,
                                    showsSelectedIndicator: workspace.id == controller.selectedWorkspace?.id)
                            }.buttonStyle(.plain).disabled(controller.isChoosingWorkspace || !controller.canAccessWorkspaces)
                                .accessibilityIdentifier("account.sync.workspace." + workspace.id)
                        }
                    }
                }.listStyle(.inset)
            }
            .navigationTitle(LingroveNibomoAccountCopy.text("settings.currentWorkspace.chooseWorkspaceTitle"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LingroveNibomoAccountCopy.text("common.close")) { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }.frame(width: 560, height: 440).preferredColorScheme(.dark).tint(.orange)
            .accessibilityIdentifier("account.sync.workspaceChooser")
    }
}

/// Extracted CloudWorkspaceSelectionRow. Lingrove has no create-new operation or creation-date
/// metadata in this capability, so those optional adornments are removed; native row layout stays.
private struct LingroveAccountWorkspaceRow: View {
    let title: String
    let showsSelectedIndicator: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) { Text(title).foregroundStyle(.primary) }
            Spacer()
            if showsSelectedIndicator { Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary) }
        }.contentShape(Rectangle()).padding(.vertical, 2)
    }
}

/// Extracted SyncStatusIndicatorView, using safe lane status instead of a mobile CloudState.
/// Each row owns one projection; independently failing review/media lanes retain their own tone.
struct LingroveSyncStatusIndicator: View {
    let status: MacNotebookSyncStatus

    var body: some View {
        HStack(spacing: 6) {
            if let toneColor { Circle().fill(toneColor).frame(width: 8, height: 8) }
            Text(MacNotebookSyncPresentation.title(status)).multilineTextAlignment(.trailing)
        }
    }

    private var toneColor: Color? {
        switch status {
        case .synchronized: .green
        case .working, .pending: .yellow
        case .unavailable, .forbidden, .failed, .conflict, .rejected: .red
        default: nil
        }
    }
}

import LingroveCloud
import LingroveNotebook
import LingroveNotebookEngine
import LingroveNotebookSync
import SwiftUI

// Workspace chooser/status UI extracted from Nibomo AccountStatusView and CloudWorkspaceSelectionSheet (MIT).
// Copyright (c) 2026 Kirill Markin. License: Lingrove/Resources/NibomoUI-LICENSE.txt.

/// This settings fragment borrows the process-owned sync controller. Picker/conflict choices are
/// view drafts only; the controller captures the saved SQL proposal and validates it on commit.
/// Reopening Settings observes the same tasks, consent and independently reported sync lanes.
struct AccountNotebookSyncSection: View {
    @ObservedObject var controller: MacNotebookSyncController
    @State private var choosingWorkspace = false
    @State private var conflictChoices: [Int: VocabularyWireConflictSelection.Choice] = [:]

    var body: some View {
        Section {
            HStack {
                Button(String(localized: "Load workspaces", table: "NotebookSync")) { controller.refreshWorkspaces() }
                    .disabled(!controller.canAccessWorkspaces || controller.isLoadingWorkspaces || controller.isChoosingWorkspace)
                    .accessibilityIdentifier("account.sync.loadWorkspaces")
                if controller.isLoadingWorkspaces || controller.isChoosingWorkspace { ProgressView().controlSize(.small) }
                Spacer()
                Text(MacNotebookSyncPresentation.title(controller.workspaceStatus)).foregroundStyle(.secondary)
            }
            Button(LingroveNibomoAccountCopy.text("settings.currentWorkspace.chooseWorkspaceTitle")) {
                choosingWorkspace = true
            }
            .disabled(!controller.canAccessWorkspaces || controller.isChoosingWorkspace || controller.workspaces.isEmpty)
            .accessibilityIdentifier("account.sync.workspace")
            if let workspace = controller.selectedWorkspace {
                LabeledContent(String(localized: "Workspace", table: "NotebookSync"), value: workspace.name)
            }
            ownershipControls
            if controller.selectedWorkspace != nil {
                Toggle(String(localized: "Enable notebook sync", table: "NotebookSync"),
                    isOn: Binding(get: { controller.enabled }, set: controller.setSynchronizationEnabled))
                    .disabled(controller.isChoosingWorkspace || controller.ownershipProposal?.status == "pending")
                    .accessibilityIdentifier("account.sync.enabled")
                lane("Corpus", status: controller.corpusStatus, identifier: "corpus")
                lane("PNG media", status: controller.mediaStatus, identifier: "media")
                lane("Built-in review", status: controller.reviewStatus, identifier: "review")
                lane("Workspace scheduler", status: controller.schedulerStatus, identifier: "scheduler")
                HStack {
                    Button(String(localized: "Retry sync", table: "NotebookSync")) { controller.retry() }
                        .disabled(!controller.enabled || controller.isChoosingWorkspace)
                        .accessibilityIdentifier("account.sync.retry")
                    Button(String(localized: "Cancel sync", table: "NotebookSync")) { controller.cancel() }
                        .disabled(!controller.enabled || controller.isChoosingWorkspace)
                        .accessibilityIdentifier("account.sync.cancel")
                }
            }
            if let connection = controller.firstConnection {
                Text(String(localized: "Cloud library choice", table: "NotebookSync")).font(.headline)
                Text(String(localized: """
                    This workspace already has a cloud library. Combine saved content or use the cloud \
                    copy; the original local content is retained.
                    """, table: "NotebookSync"))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(String(localized: "Combine saved content", table: "NotebookSync")) {
                        controller.resolveFirstConnection(combine: true, expected: connection)
                    }
                        .accessibilityIdentifier("account.sync.combineCloud")
                    Button(String(localized: "Use cloud copy", table: "NotebookSync")) {
                        controller.resolveFirstConnection(combine: false, expected: connection)
                    }
                        .accessibilityIdentifier("account.sync.useCloud")
                }
            }
        } header: {
            Text(String(localized: "Notebook sync", table: "NotebookSync"))
        } footer: {
            Text(String(localized: """
                Sync includes only saved corpus, PNGs and built-in review. It never includes writing \
                context, unsaved screenshots or logs.
                """, table: "NotebookSync"))
        }
        .onChange(of: controller.ownershipProposal?.id) { _, _ in conflictChoices = [:] }
        .onChange(of: controller.ownershipProposal?.generation) { _, _ in conflictChoices = [:] }
        .onChange(of: controller.ownershipProposal?.source.revision) { _, _ in conflictChoices = [:] }
        .onChange(of: controller.ownershipProposal?.target.revision) { _, _ in conflictChoices = [:] }
        .sheet(isPresented: $choosingWorkspace) { LingroveAccountWorkspaceSelectionSheet(controller: controller) }

    }

    @ViewBuilder private var ownershipControls: some View {
        if let proposal = controller.ownershipProposal, proposal.status != "merged" {
            Text(String(localized: "Local library", table: "NotebookSync")).font(.headline)
            LabeledContent(String(localized: "Local expressions", table: "NotebookSync"),
                value: String(proposal.source.document.catalog.count))
            Text(String(localized: """
                The original local library stays on this Mac. Accepting copies its saved material and \
                existing built-in review history into this account; collecting never enrolls new review.
                """, table: "NotebookSync"))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !proposal.conflicts.isEmpty {
                Text(String(localized: """
                    Some saved identities conflict. Choose which copy to keep before accepting.
                    """, table: "NotebookSync"))
                ForEach(Array(proposal.conflicts.indices), id: \.self) { index in
                    let conflict = proposal.conflicts[index]
                    LabeledContent(String(localized: "Local copy", table: "NotebookSync"),
                        value: MacNotebookSyncPresentation.preview(conflict.local) ?? "—")
                    LabeledContent(String(localized: "Account copy", table: "NotebookSync"),
                        value: MacNotebookSyncPresentation.preview(conflict.remote) ?? "—")
                    Picker(String(localized: "Local library", table: "NotebookSync"),
                        selection: Binding(get: { conflictChoices[index] }, set: { conflictChoices[index] = $0 })) {
                        Text("—").tag(Optional<VocabularyWireConflictSelection.Choice>.none)
                        Text(String(localized: """
                            Local copy
                            """, table: "NotebookSync")).tag(Optional(VocabularyWireConflictSelection.Choice.local))
                        Text(String(localized: """
                            Account copy
                            """, table: "NotebookSync")).tag(Optional(VocabularyWireConflictSelection.Choice.remote))
                    }
                }
            }
            HStack {
                if proposal.status == "pending" {
                    Button(String(localized: "Keep local library separate", table: "NotebookSync")) {
                        controller.resolveLocalCorpus(accept: false, expected: proposal)
                    }
                        .accessibilityIdentifier("account.sync.retainLocal")
                }
                Button(String(localized: "Accept local library", table: "NotebookSync")) {
                    controller.resolveLocalCorpus(accept: true, choices: conflictChoices, expected: proposal)
                }
                .disabled(!proposal.canCombine || proposal.conflicts.indices.contains(where: { conflictChoices[$0] == nil }))
                .accessibilityIdentifier("account.sync.acceptLocal")
            }
        }
    }

    private func lane(_ title: String.LocalizationValue, status: MacNotebookSyncStatus, identifier: String) -> some View {
        LabeledContent(String(localized: title, table: "NotebookSync")) { LingroveSyncStatusIndicator(status: status) }
            .accessibilityIdentifier("account.sync.\(identifier)")
    }
}

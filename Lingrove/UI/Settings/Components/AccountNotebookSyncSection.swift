import LingroveCloud
import LingroveNotebook
import LingroveNotebookEngine
import LingroveNotebookSync
import SwiftUI

// Workspace chooser/status UI extracted from Nibomo AccountStatusView and CloudWorkspaceSelectionSheet (MIT).
// Copyright (c) 2026 Kirill Markin. License: Lingrove/Resources/NibomoUI-LICENSE.txt.

/// This Form fragment borrows the app-owned sync controller and groups its independent decisions:
/// workspace, local ownership, explicit sync consent and lane recovery. Only conflict choices and
/// sheet presentation live here. Every write carries the exact displayed proposal, so a later
/// account/revision cannot reinterpret an old choice. It never creates a transport or repository.
struct AccountNotebookSyncSection: View {
    @ObservedObject var controller: MacNotebookSyncController
    @State private var choosingWorkspace = false
    @State private var conflictChoices: [Int: VocabularyWireConflictSelection.Choice] = [:]

    var body: some View {
        Group {
            workspaceSection
                // A single, always-mounted section owns the sheet and conflict reset observers.
                // Attaching presentation to Group can distribute it across several Form siblings.
                .onChange(of: controller.ownershipProposal?.id) { _, _ in conflictChoices = [:] }
                .onChange(of: controller.ownershipProposal?.generation) { _, _ in conflictChoices = [:] }
                .onChange(of: controller.ownershipProposal?.source.revision) { _, _ in conflictChoices = [:] }
                .onChange(of: controller.ownershipProposal?.target.revision) { _, _ in conflictChoices = [:] }
                .sheet(isPresented: $choosingWorkspace) { LingroveAccountWorkspaceSelectionSheet(controller: controller) }
            ownershipSection
            synchronizationSection
            firstConnectionSection
        }
    }

    private var workspaceSection: some View {
        Section {
            if !controller.canAccessWorkspaces {
                SettingsCalloutView(callout: .init(tone: .info,
                    message: String(localized: "Sign in to choose a workspace and set up sync.", table: "NotebookSync")))
            }
            LabeledContent {
                HStack(spacing: 8) {
                    if controller.isLoadingWorkspaces || controller.isChoosingWorkspace { ProgressView().controlSize(.small) }
                    LingroveSyncStatusIndicator(status: controller.workspaceStatus)
                    Button(String(localized: "Load workspaces", table: "NotebookSync")) { controller.refreshWorkspaces() }
                        .disabled(!controller.canAccessWorkspaces || controller.isLoadingWorkspaces || controller.isChoosingWorkspace)
                        .accessibilityIdentifier("account.sync.loadWorkspaces")
                }
            } label: {
                SettingsRowLabel(title: String(localized: "Workspace", table: "NotebookSync"), systemImage: "square.stack.3d.up")
            }
            LabeledContent {
                Button(LingroveNibomoAccountCopy.text("settings.currentWorkspace.chooseWorkspaceTitle")) { choosingWorkspace = true }
                    .disabled(!controller.canAccessWorkspaces || controller.isChoosingWorkspace || controller.workspaces.isEmpty)
                    .accessibilityIdentifier("account.sync.workspace")
            } label: {
                SettingsRowLabel(title: controller.selectedWorkspace?.name
                    ?? String(localized: "Choose a workspace", table: "NotebookSync"))
            }
            if controller.canAccessWorkspaces, !controller.isLoadingWorkspaces, controller.workspaces.isEmpty,
               controller.workspaceStatus == .ready {
                Text(String(localized: "No workspaces are available for this account.", table: "NotebookSync"))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(String(localized: "Workspace", table: "NotebookSync"))
        } footer: {
            Text(String(localized: """
                Signing in only confirms your identity. Choose a workspace, decide what to do with \
                local material, then enable sync.
                """, table: "NotebookSync"))
        }
        .settingsItem(.accountSync)
    }

    @ViewBuilder private var ownershipSection: some View {
        if let proposal = controller.ownershipProposal, proposal.status != "merged" {
            Section {
                LabeledContent(String(localized: "Local expressions", table: "NotebookSync"),
                    value: String(proposal.source.document.catalog.count))
                SettingsCalloutView(callout: .init(tone: .info, message: String(localized: """
                    The original local library stays on this Mac. Accepting copies its saved material and \
                    existing built-in review history into this account; collecting never enrolls new review.
                    """, table: "NotebookSync")))
                if !proposal.conflicts.isEmpty {
                    Text(String(localized: "Some saved identities conflict. Choose which copy to keep before accepting.",
                        table: "NotebookSync"))
                    ForEach(Array(proposal.conflicts.indices), id: \.self) { index in
                        conflictRow(proposal.conflicts[index], index: index)
                    }
                }
                HStack {
                    if proposal.status == "pending" {
                        Button(String(localized: "Keep local library separate", table: "NotebookSync")) {
                            controller.resolveLocalCorpus(accept: false, expected: proposal)
                        }
                        .accessibilityIdentifier("account.sync.retainLocal")
                    }
                    Spacer()
                    Button(String(localized: "Accept local library", table: "NotebookSync")) {
                        controller.resolveLocalCorpus(accept: true, choices: conflictChoices, expected: proposal)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!proposal.canCombine || proposal.conflicts.indices.contains(where: { conflictChoices[$0] == nil }))
                    .accessibilityIdentifier("account.sync.acceptLocal")
                }
            } header: { Text(String(localized: "Local library", table: "NotebookSync")) }
        }
    }

    @ViewBuilder private var synchronizationSection: some View {
        if controller.selectedWorkspace != nil {
            Section {
                Toggle(isOn: Binding(get: { controller.enabled }, set: controller.setSynchronizationEnabled)) {
                    SettingsRowLabel(title: String(localized: "Enable notebook sync", table: "NotebookSync"),
                        systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(controller.isChoosingWorkspace || controller.ownershipProposal?.status == "pending")
                .accessibilityIdentifier("account.sync.enabled")
            } header: {
                Text(String(localized: "Notebook sync", table: "NotebookSync"))
            } footer: {
                Text(String(localized: """
                    Sync includes only saved corpus, PNGs and built-in review. It never includes writing \
                    context, unsaved screenshots or logs.
                    """, table: "NotebookSync"))
            }
            Section(String(localized: "Sync status", table: "NotebookSync")) {
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
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder private var firstConnectionSection: some View {
        if let connection = controller.firstConnection {
            Section {
                SettingsCalloutView(callout: .init(tone: .warning, message: String(localized: """
                    This workspace already has a cloud library. Combine saved content or use the cloud \
                    copy; the original local content is retained.
                    """, table: "NotebookSync")))
                HStack {
                    Button(String(localized: "Combine saved content", table: "NotebookSync")) {
                        controller.resolveFirstConnection(combine: true, expected: connection)
                    }
                    .accessibilityIdentifier("account.sync.combineCloud")
                    Button(String(localized: "Use cloud copy", table: "NotebookSync")) {
                        controller.resolveFirstConnection(combine: false, expected: connection)
                    }
                    .accessibilityIdentifier("account.sync.useCloud")
                    Spacer()
                }
            } header: { Text(String(localized: "Cloud library choice", table: "NotebookSync")) }
        }
    }

    private func conflictRow(_ conflict: VocabularyWireConflictSelection, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent(String(localized: "Local copy", table: "NotebookSync"),
                value: MacNotebookSyncPresentation.preview(conflict.local) ?? "—")
            LabeledContent(String(localized: "Account copy", table: "NotebookSync"),
                value: MacNotebookSyncPresentation.preview(conflict.remote) ?? "—")
            Picker(String(localized: "Local library", table: "NotebookSync"),
                selection: Binding(get: { conflictChoices[index] }, set: { conflictChoices[index] = $0 })) {
                Text("—").tag(Optional<VocabularyWireConflictSelection.Choice>.none)
                Text(String(localized: "Local copy", table: "NotebookSync"))
                    .tag(Optional(VocabularyWireConflictSelection.Choice.local))
                Text(String(localized: "Account copy", table: "NotebookSync"))
                    .tag(Optional(VocabularyWireConflictSelection.Choice.remote))
            }
            .accessibilityIdentifier("account.sync.conflict.\(index)")
        }
    }

    private func lane(_ title: String.LocalizationValue, status: MacNotebookSyncStatus, identifier: String) -> some View {
        LabeledContent(String(localized: title, table: "NotebookSync")) { LingroveSyncStatusIndicator(status: status) }
            .accessibilityIdentifier("account.sync.\(identifier)")
    }
}

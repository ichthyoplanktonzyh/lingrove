// Account page structure adapted from Nibomo AccountStatusView.swift (MIT).
// Copyright (c) 2026 Kirill Markin. License: Lingrove/Resources/NibomoUI-LICENSE.txt.
import LingroveCloud
import SwiftUI

/// The Settings window lends its account navigation/draft owner and the process-owned services.
/// This pane renders identity first, then links to sync and secondary service configuration. Its
/// NavigationStack has an explicit path so an external Account action always reaches the overview
/// without discarding URL drafts or performing authentication, ownership adoption or sync opt-in.
struct AccountPaneView: View {
    @ObservedObject var account: AccountSessionService
    var syncController: MacNotebookSyncController?
    @ObservedObject var navigation = AccountSettingsNavigation()
    @State private var signingIn = false
    @State private var confirmingSignOut = false

    private var connectionIsSaved: Bool { navigation.matches(account.configuration) }
    private var hasDraftChanges: Bool { navigation.hasChanges(comparedWith: account.configuration) }

    var body: some View {
        NavigationStack(path: $navigation.path) {
            overview
                .navigationTitle(String(localized: "Account", table: "Account"))
                .navigationDestination(for: AccountSettingsPage.self) { destination in
                    switch destination {
                    case .service:
                        LingroveAccountServerView(account: account, api: $navigation.api, auth: $navigation.auth)
                    case .sync:
                        SettingsPaneScaffold(callout: draftCallout) {
                            if let syncController {
                                AccountNotebookSyncSection(controller: syncController)
                                    .disabled(!connectionIsSaved)
                            }
                        }
                        .navigationTitle(String(localized: "Notebook sync", table: "NotebookSync"))
                        .accessibilityIdentifier("account.sync.screen")
                    }
                }
        }
        .sheet(isPresented: $signingIn) {
            LingroveAccountSignInSheet(account: account, connectionIsSaved: connectionIsSaved)
        }
        .alert(String(localized: "Sign out on this Mac", table: "Account"), isPresented: $confirmingSignOut) {
            Button(LingroveNibomoAccountCopy.text("common.cancel"), role: .cancel) { }
            Button(String(localized: "Sign out on this Mac", table: "Account"), role: .destructive) { account.signOut() }
                .accessibilityIdentifier("account.signOut.confirm")
        } message: {
            Text(String(localized: """
                This clears this Mac's session. It does not delete your account or sign out other devices.
                """, table: "Account"))
        }
        .onAppear { navigation.reconcile(configuration: account.configuration) }
        .onChange(of: account.configuration) { _, configuration in navigation.reconcile(configuration: configuration) }
    }

    private var overview: some View {
        SettingsPaneScaffold(callout: draftCallout) {
            if let issue = account.issue {
                Section {
                    SettingsCalloutView(callout: .init(tone: .warning, message: AccountPresentation.message(issue)))
                        .accessibilityIdentifier("account.issue")
                }
            }
            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        if account.state.isBusy { ProgressView().controlSize(.small) }
                        Text(AccountPresentation.title(account.state)).accessibilityIdentifier("account.status")
                    }
                } label: {
                    SettingsRowLabel(title: LingroveNibomoAccountCopy.text("settings.account.status.state"),
                        systemImage: "person.crop.circle")
                }
                if let identity = account.observation.retainedIdentity {
                    LabeledContent(LingroveNibomoAccountCopy.text("settings.account.status.linkedEmail")) {
                        Text(identity.email ?? identity.userID).textSelection(.enabled)
                    }
                }
                sessionControls
            } header: {
                Text(LingroveNibomoAccountCopy.text("settings.account.status.section.accountStatus"))
            } footer: {
                Text(String(localized: """
                    Signing in only confirms your identity. Choose a workspace, decide what to do with \
                    local material, then enable sync.
                    """, table: "NotebookSync"))
            }
            .settingsItem(.accountSession)

            if let syncController {
                Section {
                    AccountSyncNavigationRow(controller: syncController)
                }
            }
            Section {
                NavigationLink(value: AccountSettingsPage.service) {
                    SettingsRowLabel(title: String(localized: "Account service", table: "Account"),
                        description: account.configuration?.apiBaseURL.absoluteString
                            ?? String(localized: "Not configured", table: "Account"),
                        systemImage: "server.rack")
                }
                .accessibilityIdentifier("account.server")
            }
            Section {
                SettingsCalloutView(callout: .init(tone: .info,
                    message: String(localized: "Your local library, review and progress work without an account.", table: "Account")))
            }
        }
        .accessibilityIdentifier("account.overview")
    }

    private var draftCallout: SettingsPaneCallout? {
        guard hasDraftChanges else { return nil }
        return .init(tone: .warning, message: String(localized: """
            Connection changes are not saved. Save or revert them before signing in or syncing.
            """, table: "Account"))
    }

    @ViewBuilder private var sessionControls: some View {
        switch account.state {
        case .signedIn:
            HStack {
                if let syncController, syncController.enabled {
                    Button(LingroveNibomoAccountCopy.text("settings.account.status.syncNow")) { syncController.retry() }
                        .disabled(!connectionIsSaved)
                }
                Spacer()
                signOutButton
            }
        case .offline:
            HStack {
                Button(String(localized: "Retry session", table: "Account")) { account.retrySession() }
                    .disabled(!connectionIsSaved).accessibilityIdentifier("account.retrySession")
                Spacer()
                signOutButton
            }
        case .working(.restoring), .working(.refreshing): signOutButton
        case .signedOut where account.issue == .secureStorage: signOutButton
        default:
            if account.configuration != nil {
                HStack {
                    Button(LingroveNibomoAccountCopy.text("settings.account.status.signIn")) { signingIn = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(!connectionIsSaved || account.state.isBusy)
                        .accessibilityIdentifier("account.signIn")
                    Spacer()
                }
            }
        }
    }

    private var signOutButton: some View {
        Button(String(localized: "Sign out on this Mac", table: "Account"), role: .destructive) { confirmingSignOut = true }
            .accessibilityIdentifier("account.signOut")
    }
}

/// Only this row subscribes to sync while the overview is visible. It reports the real workspace
/// and corpus lane; opening the link has no effect on either the selected scope or sync consent.
private struct AccountSyncNavigationRow: View {
    @ObservedObject var controller: MacNotebookSyncController

    var body: some View {
        NavigationLink(value: AccountSettingsPage.sync) {
            HStack(spacing: 12) {
                SettingsRowLabel(title: String(localized: "Notebook sync", table: "NotebookSync"),
                    description: controller.selectedWorkspace?.name ?? MacNotebookSyncPresentation.title(controller.workspaceStatus),
                    systemImage: "arrow.triangle.2.circlepath")
                Spacer(minLength: 8)
                LingroveSyncStatusIndicator(status: controller.corpusStatus)
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("account.sync.open")
    }
}

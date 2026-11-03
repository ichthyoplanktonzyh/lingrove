// Account page structure adapted from Nibomo AccountStatusView.swift (MIT).
// Copyright (c) 2026 Kirill Markin. License: Lingrove/Resources/NibomoUI-LICENSE.txt.
import LingroveCloud
import SwiftUI

/// Settings owns this navigation/draft lifetime and borrows the process-owned account and sync
/// facades. Nibomo’s status, server and sign-in screens remain separate. Unsaved endpoint drafts
/// never grant a request to the saved destination; no view creates a transport or reads Keychain.
struct AccountPaneView: View {
    @ObservedObject var account: AccountSessionService
    var syncController: MacNotebookSyncController?
    @State private var api = ""
    @State private var auth = ""
    @State private var loadedDraft = false
    @State private var signingIn = false
    @State private var confirmingSignOut = false

    private enum Destination: Hashable { case server, sync }
    private var connectionIsSaved: Bool {
        AccountConfigurationPolicy.matchesSavedConnection(api: api, auth: auth, saved: account.configuration)
    }

    var body: some View {
        NavigationStack {
            LingroveReadableContentLayout(maxWidth: lingroveReadableFormMaxWidth, horizontalPadding: 0) {
                Form {
                    Section(LingroveNibomoAccountCopy.text("settings.account.status.section.accountStatus")) {
                        LabeledContent(LingroveNibomoAccountCopy.text("settings.account.status.state")) {
                            HStack(spacing: 8) {
                                if account.state.isBusy { ProgressView().controlSize(.small) }
                                Text(AccountPresentation.title(account.state)).accessibilityIdentifier("account.status")
                            }
                        }
                        if let identity = account.observation.retainedIdentity {
                            LabeledContent(LingroveNibomoAccountCopy.text("settings.account.status.linkedEmail")) {
                                Text(identity.email ?? identity.userID).textSelection(.enabled)
                            }
                        }
                        if let configuration = account.configuration {
                            LabeledContent(LingroveNibomoAccountCopy.text("settings.account.server.apiUrl")) {
                                Text(configuration.apiBaseURL.absoluteString).font(.caption.monospaced())
                                    .multilineTextAlignment(.trailing).textSelection(.enabled)
                            }
                        }
                        if let issue = account.issue {
                            Text(AccountPresentation.message(issue)).foregroundStyle(.red)
                                .accessibilityIdentifier("account.issue")
                        }
                        Text(String(localized: """
                            Signing in only confirms your identity. Choose a workspace, decide what to do with \
                            local material, then enable sync.
                            """, table: "NotebookSync"))
                            .foregroundStyle(.secondary)
                        if account.configuration != nil, !connectionIsSaved {
                            Label(String(localized: "Save connection", table: "Account"), systemImage: "exclamationmark.circle")
                                .foregroundStyle(.secondary)
                        }
                        sessionControls
                    }.settingsItem(.accountSession)
                    Section {
                        NavigationLink(value: Destination.server) {
                            Label(String(localized: "Account service", table: "Account"), systemImage: "server.rack")
                        }.settingsItem(.accountConnection).accessibilityIdentifier("account.server")
                        if syncController != nil {
                            NavigationLink(value: Destination.sync) {
                                Label(String(localized: "Notebook sync", table: "NotebookSync"), systemImage: "arrow.triangle.2.circlepath")
                            }.accessibilityIdentifier("account.sync.open")
                        }
                    }
                    Section {
                        Text(BuiltInReviewCopy.text("description.offline")).foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped)
            }
            .navigationTitle(LingroveNibomoAccountCopy.text("settings.account.status.title"))
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .server: LingroveAccountServerView(account: account, api: $api, auth: $auth)
                case .sync:
                    if let syncController {
                        Form {
                            if !connectionIsSaved {
                                Label(String(localized: "Save connection", table: "Account"), systemImage: "exclamationmark.circle")
                            }
                            AccountNotebookSyncSection(controller: syncController).disabled(!connectionIsSaved)
                        }.formStyle(.grouped).navigationTitle(String(localized: "Notebook sync", table: "NotebookSync"))
                    }
                }
            }
        }
        .tint(.orange).preferredColorScheme(.dark)
        .sheet(isPresented: $signingIn) {
            LingroveAccountSignInSheet(account: account, connectionIsSaved: connectionIsSaved)
        }
        .alert(String(localized: "Sign out on this Mac", table: "Account"), isPresented: $confirmingSignOut) {
            Button(String(localized: "Cancel", table: "ReviewCards"), role: .cancel) { }
            Button(String(localized: "Sign out on this Mac", table: "Account"), role: .destructive) { account.signOut() }
                .accessibilityIdentifier("account.signOut.confirm")
        } message: {
            Text(String(localized: """
                This clears this Mac's session. It does not delete your account or sign out other devices.
                """, table: "Account"))
        }
        .onAppear {
            guard !loadedDraft else { return }
            loadedDraft = true
            api = account.configuration?.apiBaseURL.absoluteString ?? ""
            auth = account.configuration?.authBaseURL.absoluteString ?? ""
        }
    }

    @ViewBuilder private var sessionControls: some View {
        switch account.state {
        case .signedIn:
            if let syncController {
                Button(LingroveNibomoAccountCopy.text("settings.account.status.syncNow")) { syncController.retry() }
                    .disabled(!connectionIsSaved || !syncController.enabled)
            }
            signOutButton
        case .offline:
            Button(String(localized: "Retry session", table: "Account")) { account.retrySession() }
                .disabled(!connectionIsSaved).accessibilityIdentifier("account.retrySession")
            signOutButton
        case .working(.restoring), .working(.refreshing): signOutButton
        case .signedOut where account.issue == .secureStorage: signOutButton
        default:
            if account.configuration != nil {
                Button(LingroveNibomoAccountCopy.text("settings.account.status.signIn")) { signingIn = true }
                    .disabled(!connectionIsSaved).accessibilityIdentifier("account.signIn")
            }
        }
    }

    private var signOutButton: some View {
        Button(String(localized: "Sign out on this Mac", table: "Account"), role: .destructive) { confirmingSignOut = true }
            .accessibilityIdentifier("account.signOut")
    }
}

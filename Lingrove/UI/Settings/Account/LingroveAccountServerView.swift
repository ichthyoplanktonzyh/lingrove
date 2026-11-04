// Adapted from Nibomo Settings/Account/ServerSettingsView.swift (MIT).
// Copyright (c) 2026 Kirill Markin. License: Lingrove/Resources/NibomoUI-LICENSE.txt.
import LingroveCloud
import SwiftUI

/// This secondary Settings page borrows the window-owned drafts. It owns only confirmation
/// presentation; the account service validates and applies the saved destination. Editing or
/// reverting a field makes no request, and failed saves leave the old service and draft distinct.
struct LingroveAccountServerView: View {
    @ObservedObject var account: AccountSessionService
    @Binding var api: String
    @Binding var auth: String
    @State private var confirmingApply = false
    @State private var change = ConnectionChange.custom

    /// Confirmation captures the kind of change, while the session remains the authority that
    /// validates and applies it. None of these presentation choices contacts a service.
    private enum ConnectionChange { case custom, applicationDefault, remove }

    private var matchesSaved: Bool {
        AccountConfigurationPolicy.matchesSavedConnection(api: api, auth: auth, saved: account.configuration)
    }
    private var hasChanges: Bool { account.configuration == nil ? !api.isEmpty || !auth.isEmpty : !matchesSaved }

    var body: some View {
        SettingsPaneScaffold {
            Section(LingroveNibomoAccountCopy.text("settings.account.server.section.currentServer")) {
                if let current = account.configuration {
                    LabeledContent(String(localized: "Account service", table: "Account")) {
                        Text(AccountPresentation.sourceTitle(account.connectionSource))
                    }
                    destination(LingroveNibomoAccountCopy.text("settings.account.server.apiUrl"), current.apiBaseURL.absoluteString)
                    destination(LingroveNibomoAccountCopy.text("settings.account.server.authUrl"), current.authBaseURL.absoluteString)
                } else {
                    SettingsCalloutView(callout: .init(tone: .info,
                        message: AccountPresentation.unavailableService(account.buildConfiguration)))
                }
            }
            if account.canUseApplicationDefault {
                Section {
                    Button(String(localized: "Use app default", table: "Account")) {
                        change = .applicationDefault
                        confirmingApply = true
                    }
                    .disabled(account.state.isBusy)
                    .accessibilityIdentifier("account.useDefaultConnection")
                }
            }
            Section {
                if let issue = account.issue {
                    SettingsCalloutView(callout: .init(tone: .warning, message: AccountPresentation.message(issue)))
                        .accessibilityIdentifier("account.issue")
                }
                TextField(String(localized: "API base URL (including /v1)", table: "Account"), text: $api,
                          prompt: Text(verbatim: "https://api.example.com/v1"))
                    .textContentType(.URL).autocorrectionDisabled().accessibilityIdentifier("account.apiURL")
                    .settingsItem(.accountConnection)
                TextField(String(localized: "Authentication base URL", table: "Account"), text: $auth,
                          prompt: Text(verbatim: "https://auth.example.com"))
                    .textContentType(.URL).autocorrectionDisabled().accessibilityIdentifier("account.authURL")
                HStack {
                    Button(String(localized: "Save connection", table: "Account")) {
                        change = .custom
                        confirmingApply = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(matchesSaved || !hasChanges || account.state.isBusy)
                    .accessibilityIdentifier("account.saveConnection")
                    Button(String(localized: "Revert changes", table: "Account")) { revertDraft() }
                        .disabled(!hasChanges || account.state.isBusy)
                        .accessibilityIdentifier("account.revertConnection")
                    Spacer()
                }
            } header: {
                Text(String(localized: "Custom service", table: "Account"))
            } footer: {
                Text(String(localized: """
                    Choose services you trust. Email, codes and session tokens go to the authentication service; the API \
                    confirms your identity. Changing the connection signs out on this Mac. No service is contacted until \
                    you sign in or restore a saved session.
                    """, table: "Account"))
            }
            if account.configuration != nil {
                Section {
                    Button(String(localized: "Remove connection", table: "Account"), role: .destructive) {
                        change = .remove
                        confirmingApply = true
                    }
                    .disabled(account.state.isBusy)
                    .accessibilityIdentifier("account.removeConnection")
                }
            }
        }
        .alert(confirmationTitle, isPresented: $confirmingApply) {
            Button(LingroveNibomoAccountCopy.text("common.cancel"), role: .cancel) { }
            Button(confirmationButton, role: .destructive, action: applyChange)
            .accessibilityIdentifier("account.saveConnection.confirm")
        } message: {
            if change == .remove {
                Text(String(localized: """
                    This clears this Mac's session. It does not delete your account or sign out other devices.
                    """, table: "Account"))
            } else {
                // Repeat the exact proposed services at the consent boundary. A user reviewing
                // this alert should not have to dismiss it to discover the network destination.
                Text(LingroveNibomoAccountCopy.text("settings.account.server.confirmationMessage")
                    + "\n\n" + LingroveNibomoAccountCopy.text("settings.account.server.apiUrl") + ": " + proposedAPI
                    + "\n" + LingroveNibomoAccountCopy.text("settings.account.server.authUrl") + ": " + proposedAuth)
            }
        }
        .accessibilityIdentifier("account.server.screen")
    }

    private var confirmationTitle: String {
        switch change {
        case .remove: String(localized: "Remove connection", table: "Account")
        case .applicationDefault: String(localized: "Use app default", table: "Account")
        case .custom: LingroveNibomoAccountCopy.text("settings.account.server.confirmationTitle.apply")
        }
    }

    private var confirmationButton: String {
        change == .remove ? String(localized: "Remove connection", table: "Account")
            : LingroveNibomoAccountCopy.text("settings.account.server.confirmationButton.apply")
    }

    private var proposedAPI: String {
        change == .applicationDefault ? account.buildConfiguration.configuration?.apiBaseURL.absoluteString ?? "" : api
    }
    private var proposedAuth: String {
        change == .applicationDefault ? account.buildConfiguration.configuration?.authBaseURL.absoluteString ?? "" : auth
    }

    private func applyChange() {
        let applied: Bool
        switch change {
        case .custom: applied = account.configure(api: api, auth: auth)
        case .applicationDefault: applied = account.useApplicationDefault()
        case .remove: applied = account.removeConfiguration()
        }
        if applied { revertDraft() }
    }

    private func revertDraft() {
        api = account.configuration?.apiBaseURL.absoluteString ?? ""
        auth = account.configuration?.authBaseURL.absoluteString ?? ""
    }

    private func destination(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value).font(.caption.monospaced()).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}
